import ceylon.buffer.charset {
    utf8
}
import ceylon.interop.java {
    createJavaByteArray,
    CeylonIterable,
    javaClass
}

import com.redhat.ceylon.cmr.ceylon {
    CeylonUtils
}
import com.redhat.ceylon.common.config {
    CeylonConfig,
    DefaultToolOptions
}
import com.redhat.ceylon.common.tool {
    EnumUtil
}
import com.redhat.ceylon.compiler.typechecker.analyzer {
    UsageWarning
}
import com.redhat.ceylon.compiler.typechecker.io {
    VirtualFile
}
import com.redhat.ceylon.model.typechecker.model {
    Module
}
import com.vasileff.ceylon.dart.compiler {
    javaList,
    compileDartSP,
    Warning
}
import com.vasileff.ceylon.structures {
    ArrayListMultimap,
    HashMultimap
}
import com.vasileff.ceylon.vscode.internal {
    newDiagnostic,
    log,
    LSContext,
    modulesFromModuleDescriptors,
    flattenVirtualFiles,
    dartCompatibleModules,
    moduleNameForSourceFile,
    moduleNameForDocumentId,
    visibleModules
}

import io.typefox.lsapi {
    DiagnosticSeverity
}
import io.typefox.lsapi.impl {
    DiagnosticImpl
}

import java.io {
    ByteArrayInputStream,
    InputStream,
    JFile=File
}
import java.lang {
    Class,
    Enum
}
import java.util {
    EnumSet
}

"Returns a list of compiled documentIds and all diagnostics."
[[String*], [<String->DiagnosticImpl>*]] compileModules(
        [String*] sourceDirectories,
        {<String -> String>*} listings,
        [String*] changedDocumentIds,
        LSContext context) {

    "The full path, parent directory, and file."
    function pathParts(String path) {
        value trimmed = path.trim('/'.equals);
        value components = trimmed.split('/'.equals).sequence();

        "nonempty paths will have at least one path segment."
        assert (nonempty components);

        return ["/".join(components.exceptLast),
                "/".join(components),
                components.last];
    }

    "The path, and all parent directories."
    function directoryAndParents(String path)
        =>  let (trimmed = path.trim('/'.equals),
                segments = trimmed.split('/'.equals).sequence())
            { for (i in 1:segments.size) "/".join(segments.take(i)) };

    value files
        =   ArrayListMultimap<String, VirtualFile> {
                *listings.map((listing)
                    =>  let ([d, p, n] = pathParts(listing.key))
                        d -> object satisfies VirtualFile {
                            children = javaList<VirtualFile> {};

                            path = p;

                            name = n;

                            folder = false;

                            \iexists() => true;

                            shared actual
                            String? getRelativePath(VirtualFile ancestor)
                                =>  if (path == ancestor.path)
                                        then ""
                                    else if (ancestor.path == "")
                                        then path
                                    else if (path.startsWith("``ancestor.path``/"))
                                        then path[ancestor.path.size+1...]
                                    else null;

                            inputStream
                                =>  ByteArrayInputStream(createJavaByteArray(
                                        utf8.encode(listing.item)));

                            compareTo(VirtualFile other)
                                =>  switch (path.compare(other.path))
                                    case (smaller) -1
                                    case (larger) 1
                                    case (equal) 0;
                        })
            };

    log.debug(()=>"compiling ``files.size`` files");
    log.trace(()=>"files to compile: ``files``");

    value directories
        =   HashMultimap<String, String> {
                *files.keys.flatMap(directoryAndParents).map((directory)
                    =>  let ([d, p, n] = pathParts(directory))
                        d -> p)
            };

    class DirectoryVirtualFile satisfies VirtualFile {
        shared actual String path;

        shared new (String path) {
            this.path = path.trimLeading('/'.equals);
        }

        name = pathParts(path)[2];

        folder = true;

        \iexists() => true;

        shared actual
        String? getRelativePath(VirtualFile ancestor)
            =>  if (path == ancestor.path)
                    then ""
                else if (ancestor.path == "")
                    then path
                else if (path.startsWith("``ancestor.path``/"))
                    then path[ancestor.path.size+1...]
                else null;

        children
            =   javaList<VirtualFile> {
                    expand {
                        directories.get(path).map(DirectoryVirtualFile),
                        files.get(path)
                    };
                };

        compareTo(VirtualFile other)
            =>  switch (path.compare(other.path))
                case (smaller) -1
                case (larger) 1
                case (equal) 0;

        shared actual
        InputStream inputStream {
            throw AssertionError("Directories don't have input streams.");
        }
    }

    value dirsWithoutTrailingSlash
        =   sourceDirectories.map((d) => d[0:d.size-1]);

    value sourceVirtualFileFolders
        =   dirsWithoutTrailingSlash.collect(DirectoryVirtualFile);

    value allSourceModules
        =   modulesFromModuleDescriptors(sourceVirtualFileFolders);

    value allSourceModuleNames
        =   allSourceModules.collect(Module.nameAsString);

    value moduleNamesForBackend
        =   dartCompatibleModules(allSourceModules).collect((Module.nameAsString));

    // Compile modules for the backend including:
    //
    //      - the default module
    //      - modules that aren't cached
    //      - modules with changed files
    //      - modules with visibility to modules with changed files
    //
    // Note that a Module may be cached and stil have errors. An attempt will be made to
    // recompile Modules with errors as soon as there's a chance of a better result, that
    // is, a souce code change to the errant module or a module it can see.

    value moduleNamesWithChangedFiles
        =>  changedDocumentIds
                .map {
                    (documentId) => moduleNameForDocumentId {
                        moduleNames = moduleNamesForBackend;
                        sourceDirectories = context.sourceDirectories;
                        documentId = documentId;
                    };
                }.coalesced.distinct.sequence();

    value cacheAfterEvictions
        // must evict w/o inspecting version (iow, evict aggressively)
        =   map(context.moduleCache.filter((nameAndVersion -> m) {
                if (!m.nameAsString in allSourceModuleNames) {
                    // We don't have source code for it, so keep it.
                    //
                    // Note: this is actually safe because if we *previously* had source
                    // code for some module that was then changed or deleted, it would
                    // have been evicted at that time. So if we don't have source now,
                    // it couldn't have been loaded from source.
                    return true;
                }
                if (visibleModules(m).map(Module.nameAsString)
                        .containsAny(moduleNamesWithChangedFiles)) {
                    // the module can see one of the changed modules; evict it
                    return false;
                }
                return true; // keep it
            }));

    "Compile the default module and all modules for this backend that aren't cached."
    value moduleNamesToCompile
        =>  ["default",
             *moduleNamesForBackend.select {
                (moduleName) => cacheAfterEvictions.keys.every {
                    (nameAndVersion) => !nameAndVersion.startsWith(moduleName + "/");
                };
            }];

    log.debug("changedDocumentIds: ``changedDocumentIds``");
    log.debug("moduleNamesWithChangedFiles: ``moduleNamesWithChangedFiles``");
    log.debug("moduleNamesForBackend: ``moduleNamesForBackend``");
    log.debug("originalCache.keys: ``context.moduleCache.keys.sequence()``");
    log.debug("cacheAfterEvictions.keys: ``cacheAfterEvictions.keys``");
    log.debug("moduleNamesToCompile: ``moduleNamesToCompile``");

    for (k->m in cacheAfterEvictions) {
        // TODO clear the type cache? Disable the cache if we do concurrent builds?
        m.cache.clear();
    }

    value ceylonConfig
        =   context.ceylonConfig;

    value outputRepositoryManager
        =   context.generateOutput then
            CeylonUtils.repoManager().config(ceylonConfig).buildOutputManager();

    log.debug("compiling with generateOutput=``outputRepositoryManager exists``");

    value [cuList, status, messages, moduleManager] = compileDartSP {
        moduleFilters = moduleNamesToCompile;
        virtualFiles = sourceVirtualFileFolders;
        moduleCache = cacheAfterEvictions;
        suppressWarning = getAllSuppressWarnings(ceylonConfig);
        outputRepositoryManager = outputRepositoryManager;
    };

//    "Modules that failed to typecheck."
//    value moduleNamesWithErrors
//        =   set {
//                for (node -> message in messages)
//                if (!message.warning)
//                if (exists moduleName
//                    =   moduleNameForDocumentId {
//                            moduleNames = allSourceModuleNames;
//                            sourceDirectories = sourceDirectories;
//                            node.unit.fullPath;
//                        })
//                moduleName
//            };

    // Include all Modules from the type checker, even in the case of error, and all
    // previously cached Modules that are still valid.
    context.moduleCache
        =   map({
                for (m in moduleManager.modules.listOfModules)
                // empty or invalid module.ceylon descriptors may have nulls
                if (!m.defaultModule,
                    exists nameAsString = m.nameAsString,
                    exists version = m.version)
                nameAsString + "/" + version -> m
            }.chain(cacheAfterEvictions));

    // Now, determine what files we actually compiled so that the caller will know what
    // diagnostics can be cleared. This includes all files in all source directories that
    // are not in excluded modules.

    value skippedModuleNames
        =   allSourceModuleNames.filter(not(moduleNamesToCompile.contains));

    value compiledDocumentIds
        =   sourceVirtualFileFolders.flatMap {
                (folder) => flattenVirtualFiles(folder).map {
                    (file) => file.path -> file.getRelativePath(folder);
                };
            }.filter {
                (documentId -> sourceFile) => !skippedModuleNames.contains {
                    moduleNameForSourceFile(allSourceModuleNames, sourceFile) else "!";
                };
            }.collect(Entry.key);

    return [
        compiledDocumentIds,
        messages.filter((_ -> m)
            =>  if (is UsageWarning m)
                then !m.suppressed
                else true)
        .collect((node->message)
            =>  node.unit.fullPath -> newDiagnostic {
                    message = message.message;
                    range = rangeForMessage(message);
                    severity = message.warning
                        then DiagnosticSeverity.warning
                        else DiagnosticSeverity.error;
                })
    ];
}

[Warning*] getAllSuppressWarnings(CeylonConfig config) {
    // compiler.suppresswarning option
    value result = EnumUtil.enumsFromStrings(javaClass<Warning>(),
            DefaultToolOptions.getCompilerSuppressWarnings(config))
            else EnumSet.noneOf(javaClass<Warning>());
    // compiler.dartsuppresswarning option
    result.addAll(enumsFromStrings(javaClass<Warning>(),
            getCompilerDartSuppressWarnings(config)));
    return CeylonIterable(result).sequence();
}

[String*] getCompilerDartSuppressWarnings(CeylonConfig config)
    =>  if (exists warnings
            =   config.getOptionValues("compiler.dartsuppresswarning"))
        then warnings.iterable.coalesced.map(Object.string).sequence()
        else [];

EnumSet<EnumType> enumsFromStrings<EnumType>(
        Class<EnumType> enumClass, [String*] elements)
        given EnumType satisfies Enum<EnumType> {
    value result = EnumSet<EnumType>.noneOf(enumClass);
    value allValues = EnumSet.allOf(enumClass);
    for (element in elements.map(String.trimmed)
                            .map((String s) => s.replace("-", "_"))) {
        for (e in allValues) {
            if (e.name().equalsIgnoringCase(element)) {
                result.add(e);
            }
        }
    }
    return result;
}
