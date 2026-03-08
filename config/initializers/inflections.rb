# frozen_string_literal: true

# Zeitwerk inflections for acronym directories (e.g. lib/llm/ → LLM::)
Rails.autoloaders.each do |autoloader|
  autoloader.inflector.inflect(
    "llm" => "LLM"
  )
end
