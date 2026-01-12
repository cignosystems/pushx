defmodule PushX.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      {:finch, "~> 0.18"},
      {:joken, "~> 2.6"},
      {:goth, "~> 1.4"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp description do
    """
    Modern push notifications for Elixir. Supports Apple APNS and Google FCM
    with HTTP/2, JWT authentication, and a clean unified API.
    """
  end

  defp package do
    [
      name: "pushx",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      maintainers: ["Cigno Systems AB"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
