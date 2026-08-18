defmodule PushX.MixProject do
  use Mix.Project

  @version "0.13.0"
  @source_url "https://github.com/cignosystems/pushx"

  def project do
    [
      app: :pushx,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: test_coverage(),
      name: "PushX",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PushX.Application, []}
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.21"},
      {:joken, "~> 2.6"},
      {:goth, "~> 1.4"},
      {:telemetry, "~> 1.4"},

      # Dev/Test
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:bypass, "~> 2.1", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]}
    ]
  end

  defp test_coverage do
    [
      # Enforced by `mix test --cover` locally and in CI. Kept at the current
      # level so coverage can only ratchet up; raise it when it grows.
      summary: [threshold: 94]
    ]
  end

  defp dialyzer do
    [
      # Committed to a stable path so CI can cache the PLT between runs.
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:ex_unit]
    ]
  end

  defp description do
    """
    Push notifications for Elixir with one API for Apple APNS and Google FCM —
    automatic retries, circuit breaker, dead-token cleanup, telemetry, FCM
    topics, and per-tenant runtime credentials, with nothing to add to your
    supervision tree.
    """
  end

  defp package do
    [
      name: "pushx",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Cigno Systems AB"],
      files:
        ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md AGENTS.md pushx_logo.png assets)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "AGENTS.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      source_url: @source_url,
      # Icon-only, transparent, square: ExDoc renders the logo at 48x48 in the
      # sidebar (next to the project name it already prints) on both the light
      # and dark themes. The wordmark version (pushx_logo.png) is for README.
      logo: "assets/pushx_icon.png",
      favicon: "assets/pushx_icon.png",
      # CHANGELOG references internal modules (@moduledoc false) by name to
      # describe behaviour changes — that's expected and shouldn't warn.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      groups_for_modules: [
        "Core API": [PushX, PushX.Message, PushX.Response],
        Providers: [PushX.APNS, PushX.FCM],
        "Runtime Instances": [PushX.Instance],
        Infrastructure: [PushX.Config, PushX.Retry, PushX.Token],
        Observability: [PushX.Telemetry, PushX.CircuitBreaker, PushX.RateLimiter]
      ]
    ]
  end
end
