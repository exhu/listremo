# D Coding style
Prefered coding style is slightly different from standard D style. It's similar
to default clang: indentation is 2 spaces, opening { is on the same line as
struct/class/function/if/while etc. declaration.

Line length is 80 columns max both in D and documentation files.

## Directories and file location
D source files go to "source".
Assets/resources go to "assets".
Auxilliarly scripts go to "scripts".

## File naming
All source file names are always lower case.

## D symbol names
D code symbol names use D style naming rules, e.g. all module names lowercase,
types, classes in PascalCase; consts, variables, functions/methods, fields, enum
values in camelCase.

## D null handling
By default reference types (classes) and pointers passed to functions and in
return values cannot be null. If they are allowed to be null it must be
documented in the comment to the function/method. Insert `assert(argument !is
null)` in constructors where necessary.

If a struct or class field must not be null in all cases, add struct or class
`invariant` block with `assert(field !is null)` instead of silently creating
empty objects, or placing null checks everywhere. Disable default constructor if
the field must be initialized via an argument to a non-null value.

## const for local variables
Prefer declaring local variables const if they don't change.

## Resources and string import
Essencial static resources like fonts, images, shaders, texts, sql are embedded
into final program via D's import strings if they are small (< 200KiB).

Default directory for resources is "assets". Embedable assets via import must
be placed into "assets/\<package_name\>" to avoid conflicts when both a program
and a library use the same shader file names, e.g. "assets/org/app/font.ttf"

Put string imports into "assets.d" or into "internal/assets.d".
E.g. "source/org/app/internal/assets.d"

## Variables and constants
Prefer declaring local variables and fields const if they are not meant to change.

## Architecture & Module Visibility (D)
To preserve API stability, prevent encapsulation leaks, and protect compiler
throughput, all modules must strictly adhere to domain-bounded encapsulation.

### 1. Structure & Facades
- **No Umbrella Root Imports:** Do not provide a monolithic top-level
  `package.d` that re-exports all library subsystems. Consumers must opt into
  subsystems explicitly (e.g., `import org.app.lib.net;`).
- **Domain Facades:** Each functional subsystem must live in its own directory
  containing a `package.d` (e.g., `source/org/app/render/package.d`) if
  there are more than one module in the subsystem.
- do not create a directory for a single module file as package.d,
  a single module file is enough in this case.
- when converting a module into a package (directory with sub-modules), the
  original module becomes package.d, e.g. render.d becomes render/package.d
  containing the original code.
- do not use public reexports, first-level modules inside the package are
  the public interface.

### 2. Implementation Boundaries
- **Internal Directories:** All volatile logic, wire formats, OS bindings, and
  concrete driver classes belong in an `internal/` subdirectory under their
  respective domain or under `source/<root_pkg>/internal/` for cross-cutting
  helpers.
- **Access Control:** Do not mark internal symbols `public`. Use
  `package(<root_pkg>)` for symbols shared across the library, or file-level
  `private` for local routines. Implementation details must never be reachable
  by external consumers.

### 3. Compile-Time Overhead Rules
- Keep file-level imports in `internal/` modules strictly minimal.
- Use scoped imports inside function and template bodies for heavy standard
  library modules (e.g., `std.algorithm`, `std.format`, `std.json`) to defer
  template parsing and semantic analysis. However if multiple functions
  of a module require the same, then do not duplicate imports, but put
  single import in the start of the file.

## Visiblity attributes order
In a module, class, struct declare public methods and fields first, then
protected, and then private.

Do not apply visibility attribute (private, protected, public) per language
unit, declare a few sections instead inside a class, struct or module, e.g.
```D
module mymodule;
// GOOD
void myPublicFunction() {}
private:
// all private functions, fields, variables go after that
void myPrivateFunction() {}

// BAD
public void myPublicFunction() {}
private void myPrivateFunction() {}
```

## Function size
Split long (>50 lines) or complex functions (which have different sematic
blocks) into smaller.

## Function parameters
Put the main semantic paramter first, e.g. in drawText function put string type
the first.

In overloaded functions/methods keep the same uniform order, e.g.
```D
void drawText(string text, PointF position, ColorF color);
void drawText(string text, PointF position, ColorF color, float fontSize);
void drawText(string text, PointF position, ColorF color, float fontSize, Font font);
```
Prefer default arguments to overloaded functions.

For more than three arguments consider adding a struct type passed as `in` or `ref`,
which can be constructed with builder pattern, e.g.
```D
struct TextParameters {
  string text;
  PointF position;
  ColorF color;
  float fontSize;
  Font font;

  TextParameters* withText(string text) {
	this.text = text;
	return this;
  }

  TextParameters* withColor(ColorF color) {
	this.color = color;
	return this;
  }
  // ...
}

drawText(TextParameters().withText("abc").withColor(colors.red));

```

If struct needs calculation on final step, keep the original struct
with fields only (POD), and add a Builder struct for it which has
Struct build() method.
