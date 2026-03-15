# frozen_string_literal: true

# Loads Anima::Settings early so all components (models, tools, providers)
# can read configuration from ~/.anima/config.toml.
#
# The lib/anima/ directory is excluded from Zeitwerk autoloading (the Anima
# module is defined by the Rails application itself), so Settings must be
# required explicitly.
require "anima/settings"
