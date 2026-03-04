# Kira — The Idea

**"Pure clarity."**

Kira is a functional programming language designed for AI code generation. It's the functional sibling to [Klar](https://github.com/PhilipLudington/Klar), sharing the same "no ambiguity, no surprises" philosophy but applied to the functional paradigm.

## The Problem

Traditional functional languages evolved for human programmers, accumulating implicit behaviors that experienced developers internalize but AI models struggle with:

- **Type inference** hides types, making errors unclear and code opaque
- **Implicit currying** creates confusion at call sites
- **Lazy evaluation** introduces unpredictable performance and ordering
- **Monad complexity** adds layers of abstraction for simple effects
- **Multiple syntax forms** mean the same thing can be written many ways
- **Expression-heavy syntax** blurs the line between statements and values

These features reward expertise but punish consistency — exactly the wrong tradeoff for AI-generated code.

## The Insight

AI models generate better code when the language is **explicit, consistent, and predictable**. A language designed for AI should make every decision visible in the source text: types, effects, control flow, and returns. There should be one obvious way to write each construct, so generation is reliable and verification is local.

## The Design

Kira applies six core principles:

1. **Pure by default** — all functions are pure unless marked `effect`
2. **Explicit types everywhere** — no inference; every binding, parameter, and return type is declared
3. **Explicit effects** — IO, State, and Error are visible in function signatures
4. **One obvious way** — single syntax for each construct
5. **Strict evaluation** — no lazy surprises
6. **Statement-based syntax** — no expression-vs-statement ambiguity, explicit `return`

## What Makes It Different

Kira occupies a unique position: a functional language that prioritizes **clarity over cleverness**.

- Unlike Haskell: no type inference, no lazy evaluation, no monad towers
- Unlike OCaml: no implicit currying, no expression-based syntax
- Unlike Elm: has explicit effect tracking in the type system, not just a runtime boundary
- Unlike most FP languages: statement-based with explicit returns, like its imperative sibling Klar

The effect system is the key differentiator. Pure functions are the default. When a function performs IO, mutates state, or can fail, that's declared in its signature. The compiler enforces the boundary — pure code cannot call effectful code. This gives AI agents (and humans) a clear map of where side effects live.

## The Relationship with Klar

Klar and Kira are two sides of the same coin:

| | Klar | Kira |
|--|------|------|
| Paradigm | Imperative | Functional |
| Mutation | `var` for mutable | Immutable by default |
| Effects | Implicit (anywhere) | Explicit (tracked in types) |
| Data modeling | Structs + mutation | Algebraic data types |
| Sweet spot | Stateful systems, GUIs, servers | Data pipelines, parsers, business logic |

They share: explicit types, explicit returns, statement-based syntax, no inference, no implicit behavior, one syntax per construct. They interoperate — Klar code is treated as effectful from Kira's perspective, and Kira pure functions are just functions from Klar's perspective.

## The Bet

The bet is that as AI writes more code, language design needs to shift. Languages optimized for human expressiveness (terse, implicit, flexible) are suboptimal for AI generation (where explicit, consistent, and verifiable wins). Kira is a language designed from scratch for this new reality — where the primary "author" may be an AI and the primary "reader" is both human and machine.
