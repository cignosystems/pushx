# Credo runs in CI with `--strict`; keep this file in sync with what CI enforces.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      strict: true,
      checks: %{
        extra: [
          # Depth-3 nesting (a case inside an if inside a function head) is
          # idiomatic on the send paths; Credo's default max of 2 flags it.
          {Credo.Check.Refactor.Nesting, max_nesting: 3},
          # The test-only Bypass response helpers route many response shapes
          # through one function — high branch count by design, not logic to
          # untangle. Library code stays at the default threshold.
          {Credo.Check.Refactor.CyclomaticComplexity, files: %{excluded: ["test/"]}}
        ]
      }
    }
  ]
}
