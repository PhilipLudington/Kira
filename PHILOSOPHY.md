# Kira — Philosophy

## Clarity Is the Feature

Most languages treat clarity as a nice-to-have. Kira treats it as the product. Every design decision is filtered through one question: **does this make the code's meaning more obvious?** If a feature adds power but reduces clarity, it doesn't ship.

## Say What You Mean

Kira rejects implicit behavior in all forms:

- **No type inference.** If a binding has a type, you wrote that type. The compiler checks it — it doesn't guess it.
- **No implicit conversions.** An `i32` is not an `i64`. You say when you want a conversion, and you say how.
- **No implicit returns.** The last expression in a block is not the return value. You write `return`.
- **No implicit currying.** A function call looks like its definition. All arguments are present.
- **No implicit effects.** A pure function cannot print, read files, or mutate state. If it does those things, the signature says so.

The cost is verbosity. The payoff is that reading any line of Kira tells you exactly what it does without checking three other files.

## One Way

When there are two ways to do something, someone will use the wrong one. When there are five ways, everyone will use a different one.

Kira provides one syntax per construct. One way to define a function. One way to return a value. One way to branch on data. This is a constraint, not a limitation — it means every Kira program reads the same way, whether written by a human, an AI, or a team of both.

## Purity as Default, Effects as Declaration

The most important line in a Kira function is the one you don't see: the absence of `effect`. A function without that keyword is pure — deterministic, side-effect-free, safe to call anywhere, safe to reorder, safe to memoize, safe to test without mocks.

When a function needs to touch the world — read a file, print to the screen, talk to a database — it declares that with `effect`. This isn't ceremony; it's information. The type signature becomes a contract that tells you exactly what a function can do, not just what it returns.

The boundary between pure and effectful code is the most valuable line in any codebase. Kira makes it visible.

## Types as Documentation

In Kira, types are not metadata the compiler uses and humans ignore. They are the primary documentation of what code does:

- A function signature tells you its inputs, outputs, and whether it has effects
- A type definition tells you what shapes data can take
- A pattern match tells you every case that exists

Because types are always explicit and always present, they are always accurate. They cannot drift from the implementation the way comments and docs can.

## Designed for Two Readers

Every line of Kira is written to be read by two audiences: humans and AI models.

For humans, explicitness means you can understand code locally — you don't need to hold the whole program in your head to know what a function does.

For AI, consistency means generation is reliable — there's one pattern to learn per construct, and verification is mechanical. An AI can check its own output against the type system without ambiguity.

This is not a compromise between the two audiences. Explicitness serves both equally. The features that make code hard for AI (inference, implicit behavior, multiple syntax forms) also make code hard for humans who didn't write it.

## Functional, Not Academic

Kira is a functional language that doesn't require a PhD to use. It has algebraic data types, pattern matching, higher-order functions, and immutability — the proven ideas from functional programming. It does not have monads, type classes, higher-kinded types, or dependent types.

The effect system is simple: mark a function `effect` if it touches the world. No monad transformers. No effect algebras. No free monads. Just a keyword and a compiler that enforces the boundary.

This is a deliberate choice. The goal is not to be the most expressive functional language. The goal is to be the most clear one.

## Constraints Enable Trust

Every constraint in Kira exists to make a guarantee:

| Constraint | Guarantee |
|------------|-----------|
| No type inference | Types are always visible and correct |
| No implicit returns | Control flow is always explicit |
| No implicit effects | Pure functions are truly pure |
| One syntax per construct | Code reads the same everywhere |
| Strict evaluation | Execution order matches source order |
| Exhaustive pattern matching | All cases are handled |

These constraints reduce what you can write. They also reduce what can go wrong. In a world where AI generates code and humans review it, that tradeoff is worth making every time.
