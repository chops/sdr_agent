# Reach architecture policy template.
#
# Rendered placeholders:
#   * app_module     -> core app module
#   * app_web_module -> web app module
#
# First-run baseline:
#   mix reach.check --arch --write-baseline .reach-baseline.json
#
# Do not enable hard failure until .reach-baseline.json exists and the project
# explicitly opts in with REACH_ENFORCE=1. Smell checks are intentionally left
# to Reach defaults and must remain advisory unless a project promotes them.

[
  layers: [
    core: [
      "SdrAgent",
      "SdrAgent.*"
    ],
    web: [
      "SdrAgentWeb",
      "SdrAgentWeb.*"
    ]
  ],
  deps: [
    forbidden: [
      # Core domain code must not depend on Phoenix/web modules.
      {:core, :web}
    ]
  ],
  calls: [
    forbidden: [
      # Web modules should call the core public API, not the Repo or query layer directly.
      {
        ["SdrAgentWeb", "SdrAgentWeb.*"],
        ["SdrAgent.Repo.*", "Ecto.Query.*"]
      },

      # Core domain modules must never reach back into Phoenix/web modules.
      {
        ["SdrAgent", "SdrAgent.*"],
        ["SdrAgentWeb", "SdrAgentWeb.*"]
      }
    ]
  ],
  checks: [
    baseline: ".reach-baseline.json",
    layer_coverage: [
      require_all_modules: false,
      forbid_multiple_matches: true,
      ignore: [
        "SdrAgent.MixProject",
        "SdrAgentWeb.MixProject"
      ]
    ]
  ]
]
