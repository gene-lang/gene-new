// The one JS line the web profile requires, for every spec shell.
//
//   node tools/web_spec.mjs web_world
//
// A web-profile module exports an entry and the host calls it — there are no
// top-level statements in the profile, which is why the player page ends by
// importing the client and calling its `main`. This is that, made generic.
// Everything else a shell does is `tests/checks/web_*.gene`, in the language under
// test; what is left here is the call, which cannot be.
const name = process.argv[2];
if (!name) { console.error("usage: node tools/web_spec.mjs <web_spec_module>"); process.exit(2); }
const mod = await import(new URL(`../dist/${name}.mjs`, import.meta.url).pathname);
mod.main();
