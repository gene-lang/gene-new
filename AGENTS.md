## Language and implementation principles

When working on any Gene feature, example, library, or application, keep the **spirit and core design of Gene** in mind.

Applications and examples are also opportunities to test the language itself. If something feels awkward, unnecessarily difficult, inconsistent, or missing, do not simply work around it. Consider whether the underlying language, standard library, tooling, or runtime should be improved instead. Record such issues and, when appropriate, fix them as part of the work.

### Preserve the language design

Do not introduce or change Gene syntax without consulting the project owner first.

Syntax and language semantics are core design decisions, and the project owner's preferences are important. When existing syntax makes an implementation difficult, first look for solutions in the compiler, runtime, APIs, libraries, or implementation strategy rather than changing the language surface.

Larger semantic changes should likewise be surfaced explicitly rather than introduced indirectly while implementing an application or library.

### Grow the standard library when applications expose gaps

When implementation work repeatedly needs functionality that Gene does not yet provide, consider whether that functionality belongs in the Gene ecosystem rather than implementing an application-specific workaround.

As a general rule:

* **Common, broadly useful functionality** should be added to Gene's standard library under `gene/`.
* **Less common, specialized, platform-specific, or heavier functionality** should generally be added under `genex/`.
* Application-local code should remain local when it is genuinely specific to that application.

Prefer small, composable APIs that fit Gene's existing design over wrappers copied directly from another language's conventions.

### Prefer Gene for project tooling

Ideally, developing and using Gene should not require Shell, Python, or another programming language for ordinary project tasks.

When a build script, migration tool, test harness, code generator, launcher, or maintenance task appears to require another language, first ask:

> Is this exposing a missing Gene library or runtime capability that we should add?

If so, add the necessary reusable functionality to `gene/` or `genex/` and write the tooling in Gene.

Shell or another language is still reasonable when it is genuinely required for bootstrapping, interacting with external tooling before Gene can run, or using functionality that cannot reasonably be provided by Gene yet. Treat those cases as exceptions rather than the default.

The long-term goal is that **Gene is capable of building substantial applications and supporting its own development using Gene itself**.
