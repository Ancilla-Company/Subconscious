import 'package:highlight/highlight.dart' show Mode;
import 'package:highlight/languages/bash.dart' as highlight_bash;
import 'package:highlight/languages/cpp.dart' as highlight_cpp;
import 'package:highlight/languages/cs.dart' as highlight_csharp;
import 'package:highlight/languages/css.dart' as highlight_css;
import 'package:highlight/languages/dart.dart' as highlight_dart;
import 'package:highlight/languages/go.dart' as highlight_go;
import 'package:highlight/languages/java.dart' as highlight_java;
import 'package:highlight/languages/javascript.dart' as highlight_javascript;
import 'package:highlight/languages/json.dart' as highlight_json;
import 'package:highlight/languages/kotlin.dart' as highlight_kotlin;
import 'package:highlight/languages/php.dart' as highlight_php;
import 'package:highlight/languages/plaintext.dart' as highlight_plaintext;
import 'package:highlight/languages/python.dart' as highlight_python;
import 'package:highlight/languages/ruby.dart' as highlight_ruby;
import 'package:highlight/languages/rust.dart' as highlight_rust;
import 'package:highlight/languages/sql.dart' as highlight_sql;
import 'package:highlight/languages/swift.dart' as highlight_swift;
import 'package:highlight/languages/typescript.dart' as highlight_typescript;
import 'package:highlight/languages/xml.dart' as highlight_xml;
import 'package:highlight/languages/yaml.dart' as highlight_yaml;

/// The syntax highlighting mode for a file, chosen by its extension.
Mode languageForPath(String path) {
  final String lower = path.toLowerCase();
  final int dot = lower.lastIndexOf('.');
  final String extension = dot < 0 ? '' : lower.substring(dot + 1);
  return switch (extension) {
    'dart' => highlight_dart.dart,
    'js' || 'jsx' || 'mjs' || 'cjs' => highlight_javascript.javascript,
    'ts' || 'tsx' => highlight_typescript.typescript,
    'py' => highlight_python.python,
    'java' => highlight_java.java,
    'kt' || 'kts' => highlight_kotlin.kotlin,
    'swift' => highlight_swift.swift,
    'go' => highlight_go.go,
    'rs' => highlight_rust.rust,
    'rb' => highlight_ruby.ruby,
    'php' => highlight_php.php,
    'c' || 'h' || 'cc' || 'cpp' || 'cxx' || 'hpp' => highlight_cpp.cpp,
    'cs' => highlight_csharp.cs,
    'sh' || 'bash' || 'zsh' || 'ps1' || 'bat' || 'cmd' => highlight_bash.bash,
    'json' || 'jsonc' => highlight_json.json,
    'yaml' || 'yml' => highlight_yaml.yaml,
    'xml' || 'html' || 'htm' || 'svg' => highlight_xml.xml,
    'css' || 'scss' || 'sass' || 'less' => highlight_css.css,
    'sql' => highlight_sql.sql,
    _ => highlight_plaintext.plaintext,
  };
}
