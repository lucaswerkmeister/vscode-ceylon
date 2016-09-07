native ("jvm")
module com.vasileff.ceylon.vscode "0.0.0" {
    import java.base "7";
    import ceylon.interop.java "1.3.0";
    import com.redhat.ceylon.typechecker "1.3.0";
    import com.vasileff.ceylon.structures "1.0.0";
    import maven:"io.typefox.lsapi:io.typefox.lsapi" "0.3.0-SNAPSHOT";
    import maven:"io.typefox.lsapi:io.typefox.lsapi.services" "0.3.0-SNAPSHOT";
    import maven:"io.typefox.lsapi:io.typefox.lsapi.annotations" "0.3.0-SNAPSHOT";

    // shouldn't be necessary, but is:
    import maven:"org.eclipse.xtend:org.eclipse.xtend.lib" "2.10.0";
    import maven:"org.eclipse.xtext:org.eclipse.xtext.xbase.lib" "2.10.0";
}
