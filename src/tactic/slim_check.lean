/-
Copyright (c) 2020 Simon Hudon. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Simon Hudon
-/

import testing.slim_check.testable

/-!
## Finding counterexamples automatically using `slim_check`

A proposition can be tested by writing it out as:

```lean
example (xs : list ℕ) (w : ∃ x ∈ xs, x < 3) : ∀ y ∈ xs, y < 5 := by slim_check
-- ===================
-- Found problems!

-- xs := [0, 5]
-- x := 0
-- y := 5
-- -------------------

example (x : ℕ) (h : 2 ∣ x) : x < 100 := by slim_check
-- ===================
-- Found problems!

-- x := 258
-- -------------------

example (α : Type) (xs ys : list α) : xs ++ ys = ys ++ xs := by slim_check
-- ===================
-- Found problems!

-- α := ℤ
-- xs := [-4]
-- ys := [1]
-- -------------------

example : ∀ x ∈ [1,2,3], x < 4 := by slim_check
-- Success
```

In the first example, `slim_check` is called on the following goal:

```lean
xs : list ℕ,
h : ∃ (x : ℕ) (H : x ∈ xs), x < 3
⊢ ∀ (y : ℕ), y ∈ xs → y < 5
```

The local constants are reverted and an instance is found for
`testable (∀ (xs : list ℕ), (∃ x ∈ xs, x < 3) → (∀ y ∈ xs, y < 5))`.
The `testable` instance is supported by instances of `sampleable (list ℕ)`,
`decidable (x < 3)` and `decidable (y < 5)`. `slim_check` builds a
`testable` instance step by step with:

```
- testable (∀ (xs : list ℕ), (∃ x ∈ xs, x < 3) → (∀ y ∈ xs, y < 5))
                                     -: sampleable (list xs)
- testable ((∃ x ∈ xs, x < 3) → (∀ y ∈ xs, y < 5))
- testable (∀ x ∈ xs, x < 3 → (∀ y ∈ xs, y < 5))
- testable (x < 3 → (∀ y ∈ xs, y < 5))
                                     -: decidable (x < 3)
- testable (∀ y ∈ xs, y < 5)
                                     -: decidable (y < 5)
```

`sampleable (list ℕ)` lets us create random data of type `list ℕ` in a way that
helps find small counter-examples.  Next, the test of the proposition
hinges on `x < 3` and `y < 5` to both be decidable. The
implication between the two could be tested as a whole but it would be
less informative. Indeed, if we generate lists that only contain numbers
greater than `3`, the implication will always trivially hold but we should
conclude that we haven't found meaningful examples. Instead, when `x < 3`
does not hold, we reject the example (i.e.  we do not count it toward
the 100 required positive examples) and we start over. Therefore, when
`slim_check` prints `Success`, it means that a hundred suitable lists
were found and successfully tested.

If no counter-examples are found, `slim_check` behaves like `admit`.

`slim_check` can also be invoked using `#eval`:

```lean
#eval slim_check.testable.check (∀ (α : Type) (xs ys : list α), xs ++ ys = ys ++ xs)
-- ===================
-- Found problems!

-- α := ℤ
-- xs := [-4]
-- ys := [1]
-- -------------------
```

For more information on writing your own `sampleable` and `testable`
instances, see `testing.slim_check.testable`.
-/

namespace tactic.interactive
open tactic slim_check

declare_trace slim_check.instance
declare_trace slim_check.decoration
declare_trace slim_check.discared
open expr

/-- Tree structure representing a `testable` instance. -/
meta inductive instance_tree
| node : name → expr → list instance_tree → instance_tree

/-- Gather information about a `testable` instance. Given
an expression of type `testable ?p`, gather the
name of the `testable` instances that it is built from
and the proposition that they test. -/
meta def summarize_instance : expr → tactic instance_tree
| (lam n bi d b) := do
   v ← mk_local' n bi d,
   summarize_instance $ b.instantiate_var v
| e@(app f x) := do
   `(testable %%p) ← infer_type e,
   xs ← e.get_app_args.mmap_filter (try_core ∘ summarize_instance),
   pure $ instance_tree.node e.get_app_fn.const_name p xs
| e := do
  failed

/-- format a `instance_tree` -/
meta def instance_tree.to_format : instance_tree → tactic format
| (instance_tree.node n p xs) := do
  xs ← format.join <$> (xs.mmap $ λ t, flip format.indent 2 <$> instance_tree.to_format t),
  ys ← pformat!"testable ({p})",
  pformat!"+ {n} :{format.indent ys 2}\n{xs}"

meta instance instance_tree.has_to_tactic_format : has_to_tactic_format instance_tree :=
⟨ instance_tree.to_format ⟩

/--
`slim_check` considers a proof goal and tries to generate examples
that would contradict the statement.

Let's consider the following proof goal.

```lean
xs : list ℕ,
h : ∃ (x : ℕ) (H : x ∈ xs), x < 3
⊢ ∀ (y : ℕ), y ∈ xs → y < 5
```

The local constants will be reverted and an instance will be found for
`testable (∀ (xs : list ℕ), (∃ x ∈ xs, x < 3) → (∀ y ∈ xs, y < 5))`.
The `testable` instance is supported by an instance of `sampleable (list ℕ)`,
`decidable (x < 3)` and `decidable (y < 5)`.

Examples will be created in ascending order of size (more or less)

The first counter-examples found will be printed and will result in an error:

```
===================
Found problems!

xs := [1, 28]
x := 1
y := 28
-------------------
```

If `slim_check` successfully tests 100 examples, it acts like
admit. If it gives up or finds a counter-example, it reports an error.

For more information on writing your own `sampleable` and `testable`
instances, see `testing.slim_check.testable`.

Optional arguments given with `slim_check_cfg`
 * num_inst (default 100): number of examples to test properties with
 * max_size (default 100): final size argument
 * enable_tracing (default ff): enable the printing of discarded samples

Options:
  * `set_option trace.slim_check.decoration true`: print the proposition with quantifier annotations
  * `set_option trace.slim_check.discarded true`: print the examples discarded because they do not satisfy assumptions
  * `set_option trace.slim_check.instance true`: print the instances of `testable` being used to test the proposition
-/
meta def slim_check (cfg : slim_check_cfg := {}) : tactic unit := do
{ tgt ← retrieve $ tactic.revert_all >> target,
  let tgt' := tactic.add_decorations tgt,
  let cfg := { cfg with enable_tracing := cfg.enable_tracing || is_trace_enabled_for `slim_check.discared },
  inst ← mk_app ``testable [tgt'] >>= mk_instance <|>
    fail!"Failed to create a `testable` instance for `{tgt}`.
What to do:
1. make sure that the types you are using have `sampleable` instances (you can use `#sample my_type` if you are unsure);
2. make sure that the relations and predicates that your proposition use are decidable;
3. make sure that instances of `testable` exist that, when combined, apply to your decorated proposition:
```
{tgt'}
```

Use `set_option trace.class_instances true` to understand what instances are missing.",
  e ← mk_mapp ``testable.check [tgt, `(cfg), tgt', inst],
  when_tracing `slim_check.decoration trace!"[testable decoration]\n  {tgt'}",
  when_tracing `slim_check.instance   $ do
  { inst ← summarize_instance inst >>= pp,
    trace!"\n[testable instance]{format.indent inst 2}" },
  code ← eval_expr (io bool) e,
  b ← unsafe_run_io code,
  if b then admit else failed }

end tactic.interactive
