# Unit function results

For issues #85 and #46, a named function without a return type annotation has an implicit `unit` result; its result is not inferred from its body. Explicit and implicit `unit` have identical semantics: both accept a final expression or an explicit `return` carrying any value, evaluate that expression for its effects, discard its value, and return `unit`. This preserves effect-oriented function bodies while ensuring that the runtime result agrees with the static type, unlike the bootstrap behavior that exposes a non-unit value through a unit-typed call.

A lambda without an expected function type infers its result from its body. In an expected function type with a `unit` result, a lambda instead evaluates its return expressions for their effects, discards their values, and returns `unit`. This keeps value-producing callbacks available while allowing effect-oriented callbacks to end in any expression.

An existing function with a non-unit result cannot be assigned or passed as a function with a `unit` result. Function result covariance does not make `unit` a supertype of other result types; the current unifier exception accepts such assignments without adapting the runtime value. Reject these assignments rather than introducing automatic adaptation; an explicit lambda can discard the result when needed.
