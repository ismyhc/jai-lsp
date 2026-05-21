// Build metaprogram for jai-lsp.
//
// Run with: jai build.jai
//
// Produces ./jai-lsp at the project root. We drive the build through a
// metaprogram so the executable name is pinned regardless of the source file
// passed on the command line, and so we have a single place to wire in future
// build-time concerns (release flags, plugins, generated tables, etc.).

#import "Basic";
#import "Compiler";

build :: () {
    w := compiler_create_workspace("jai-lsp");
    if !w {
        print("Failed to create workspace.\n");
        return;
    }

    options := get_build_options(w);
    options.output_executable_name = "jai-lsp";
    options.output_path            = "./";
    set_build_options(options, w);

    add_build_file("src/main.jai", w);

    // Don't emit an executable for the metaprogram itself.
    set_build_options_dc(.{do_output=false});
}

#run build();
