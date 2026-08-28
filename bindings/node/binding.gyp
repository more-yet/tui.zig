{
  "targets": [
    {
      "target_name": "tui_zig",
      "sources": ["addon.cc"],
      "include_dirs": ["../../include"],
      "libraries": ["-L<(module_root_dir)/../../zig-out/lib", "-ltui"],
      "cflags_cc": ["-std=c++17", "-fexceptions", "-Wall", "-Wextra", "-Werror"],
      "xcode_settings": {
        "CLANG_CXX_LANGUAGE_STANDARD": "c++17",
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "WARNING_CFLAGS": ["-Wall", "-Wextra", "-Werror"]
      }
    }
  ]
}
