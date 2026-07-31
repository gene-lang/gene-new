// The entire program is Gene. This file exists because a browser needs an
// entry point it can <script src>, and an ES module's default export is not
// self-executing — it is three lines of glue, not game code.
import { boot } from "./dist/main.mjs";
boot();
