# Quirks do naprawienia w chicc

Quirki odkryte w starym kompilatorze JVM (quirks.md), które nadal występują w self-hosted kompilatorze.
Przetestowane 2026-04-03 za pomocą `./native/chi run`.

---

## Q5: Identyfikatory kolidujące z reserved words Lua

**Problem:** Emitter generuje identyfikatory Chi dosłownie do Lua. Nazwy będące słowami
kluczowymi Lua (`repeat`, `until`, `do`, `end`, `then`, `local`, `nil`, `goto` itd.)
powodują błąd parsowania wygenerowanego kodu.

**Przykład:**
```chi
fn repeat(s: string, n: int): string { s }
// Lua load error: '<name>' expected near 'repeat'
```

**Rozwiązanie:** Mangling identyfikatorów w emitterze.

- Dodać funkcję `luaName(name: string): string` w `chicc/emitter.chi`
- Jeśli `name` jest na liście reserved words Lua → zwraca `_chi_{name}` (np. `_chi_repeat`)
- Jeśli nie → zwraca `name` bez zmian
- Przepuścić przez `luaName()` każde miejsce w emitterze gdzie generowany jest identyfikator
  użytkownika (zmienne, funkcje, parametry, pola rekordów, nazwy importów)

**Lista do manglowania** (Lua 5.1/LuaJIT keywords + niebezpieczne builtiny):

Keywords: `and`, `break`, `do`, `else`, `elseif`, `end`, `false`, `for`, `function`,
`goto`, `if`, `in`, `local`, `nil`, `not`, `or`, `repeat`, `return`, `then`, `true`,
`until`, `while`

Builtiny: `type`, `error`, `load`, `require`, `select`, `pairs`, `ipairs`, `next`,
`pcall`, `xpcall`, `tostring`, `tonumber`, `unpack`, `rawget`, `rawset`

**Gdzie:** `chicc/emitter.chi` — wszędzie gdzie emitowany jest identyfikator użytkownika,
głównie `emitVariableAccess` (linia ~131), `emitNameDeclaration` (linia ~200),
`emitPrefixOp` (linia ~545), parametry funkcji, pola rekordów.

**Testy:**
```chi
fn repeat(s: string): string { s }
println(repeat("ok"))  // powinno wypisać: ok

val type = 42
println(type)  // powinno wypisać: 42
```

---

## Q6+Q9: Arytmetyka mieszana int/float

**Problem:** Operator unary minus i operatory arytmetyczne (`+`, `-`, `*`, `/`, `%`)
wymagają obu operandów tego samego typu. Wyrażenie `-3.14` daje błąd bo `-` oczekuje
`int`, a `3.14` to `float`. Wyrażenie `floor(3.7) + 1` daje błąd bo `float + int`.

**Przykłady:**
```chi
import std/math { abs, floor }
abs(-3.14)        // TYPE_MISMATCH: Expected 'int' but got 'float'
floor(3.7) + 1    // TYPE_MISMATCH: Expected 'float' but got 'int'
```

**Rozwiązanie:** Numeric widening w typerze — `int` jest automatycznie promowany do `float`
gdy drugi operand to `float`.

Semantyka:
- `int op int → int` (bez zmian)
- `float op float → float` (bez zmian)
- `int op float → float` (nowe)
- `float op int → float` (nowe)
- unary `-float → float` (nowe)

**Gdzie zmienić:**

1. **`chicc/typer.chi`, linia ~685 (infix_op, branch `else`)** — obecnie tworzy fresh
   variable i dodaje constraint `result = lhs, result = rhs`, co wymusza `lhs = rhs`.
   Zamiast tego: jeśli jeden operand to `int` a drugi `float`, wynik to `float` bez
   dodawania constraint równości między operandami.

2. **`chicc/typer.chi`, linia ~712 (prefix_op)** — obecnie constraint na `bool` (obsługuje
   tylko `!`). Dodać obsługę `-`: jeśli operand to `int` → `int`, jeśli `float` → `float`.

**Testy:**
```chi
import std/math { abs, floor }

// unary minus na float
val a = -3.14
println(a)            // -3.14

// mieszana arytmetyka
val b = 1 + 2.5
println(b)            // 3.5

val c = floor(3.7) + 1
println(c)            // 4.0

// int + int nadal int
val d = 2 + 3
println(d)            // 5
```

---

## Q7: `return` z podtypem typu sumacyjnego

**Problem:** `return x` (gdzie `x: int`) wewnątrz funkcji zwracającej `int | unit` daje
błąd: "Expected type is 'unit' but got 'int'".

Przypisanie `val x: int | unit = 42` i przekazanie jako argument `foo(42)` gdzie
`foo(a: int | unit)` działają poprawnie — problem jest tylko w checku `return`.

**Przykład:**
```chi
fn firstNeg(arr: array[int]): int | unit {
    // ...
    return arr[i]  // TYPE_MISMATCH: Expected 'unit' but got 'int'
}
```

**Rozwiązanie:** Poprawić return type check w `chicc/checks.chi`.

**Gdzie:** `chicc/checks.chi`, linia ~565 (`rtWalkExprImpl`, branch `kind == "return"`).

Obecnie:
1. Porównuje `typeEquals(actualType, expectedReturnType)` → strict equality
2. Fallback: próbuje unifikację → też nie rozumie subtyping sum types

Brakuje sprawdzenia: jeśli `expectedReturnType` ma `tag == "sum"`, to sprawdzić czy
`actualType` jest jednym z wariantów (typów składowych) tego sum type.

Dodać przed/zamiast unifikacji:
```
jeśli expRet.tag == "sum":
    dla każdego typu T w expRet.types:
        jeśli typeEquals(actualType, T) → OK, nie zgłaszaj błędu
```

**Testy:**
```chi
import std/lang.array { size }

fn firstNeg(arr: array[int]): int | unit {
    var i = 1
    while i <= arr.size() {
        if arr[i] < 0 { return arr[i] }
        i = i + 1
    }
}
println(firstNeg([1, -5, 3]))   // -5
println(firstNeg([1, 2, 3]))    // unit
```

---

## B3: IIFE (Immediately Invoked Block) nie wspierane

**Problem:** Wzorzec `{ ... }()` — blok natychmiast wywołany jako funkcja bezargumentowa —
nie jest obsługiwany. Blok `{ ... }` bez `->` jest parsowany jako `ParseBlock`, nie lambda.
Gdy `()` następuje po bloku, typ checker widzi wywołanie na typie `unit` i zgłasza błąd.

**Przykład:**
```chi
// lang.generator.chi, linia 31
{
    val g = generator(0) { last ->
        if last > 10 { unit } else { last + 1 }
    }
    var x = g.initialValue
    while true {
        x = g.nextValue(x)
        if x == unit { break }
        println(x)
    }
}()    // TYPE_MISMATCH: Expected type is 'unit' but got 'function'
```

**Root cause:** W `ast_converter.chi`, `convertFnCallImpl` (linia ~557) konwertuje callee
przez `convertExpr`, ale nigdy nie sprawdza czy callee jest blokiem. Blok-jako-argument
jest już obsługiwany (linie ~596-612 zawijają blok w zero-arg lambdę), ale brakuje
analogicznej obsługi gdy **sam callee** jest blokiem.

**Rozwiązanie:** W `ast_converter.chi`, w `convertFnCallImpl`, po konwersji callee sprawdzić
czy oryginalny callee to `ParseBlock` (lub `kind == "block"`). Jeśli tak i argumentów jest 0,
zawinąć go w zero-arg lambdę przed utworzeniem `FnCall`.

**Gdzie:** `chicc/ast_converter.chi` — `convertFnCallImpl`, po linii ~557.

**Testy:**
```chi
val result = {
    val x = 10
    x + 5
}()
println(result)  // powinno wypisać: 15
```

---

## Kolejność implementacji

1. **Q7** (return + sum type) — najprostszy fix, punktowa zmiana w `checks.chi`
2. **B3** (IIFE) — punktowa zmiana w `ast_converter.chi`, jeden warunek
3. **Q5** (mangling) — mechaniczny ale szeroki, wymaga przejścia przez cały emitter
4. **Q6+Q9** (numeric widening) — zmiana semantyki typera, wymaga starannego testowania
