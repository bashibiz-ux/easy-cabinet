# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module EasyCabinet
  EXTENSION_NAME = 'Easy Cabinet' unless const_defined?(:EXTENSION_NAME)

  # Set again on every load, so installing a newer version over a running one is
  # noticed (see EasyCabinet.reload_if_updated in main.rb).
  remove_const(:EXTENSION_VERSION) if const_defined?(:EXTENSION_VERSION)
  EXTENSION_VERSION = '1.77.1'

  if file_loaded?(__FILE__)
    # Loaded again after an install or update: swap in the new code, no restart needed.
    EasyCabinet.reload_if_updated if EasyCabinet.respond_to?(:reload_if_updated)
  else
    extension = SketchupExtension.new(EXTENSION_NAME, 'easy_cabinet/main')
    extension.description = 'Parametric kitchen cabinet generator with a control panel, ' \
                            'animated doors, handles and toe kicks.'
    extension.version   = EXTENSION_VERSION
    extension.creator   = 'Bashi'
    extension.copyright = 'Copyright 2026 Bashi'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end