# frozen_string_literal: true

# Easy Cabinet: registers the extension. The code is in the easy_cabinet folder (see easy_cabinet/main.rb).
module EasyCabinet
  EXTENSION_NAME = 'Easy Cabinet' unless const_defined?(:EXTENSION_NAME)
  EXTENSION_VERSION = '1.81.1' unless const_defined?(:EXTENSION_VERSION)

  # Installing over a running copy loads this file again: the extension is registered once.
  unless const_defined?(:EXTENSION)
    EXTENSION = SketchupExtension.new(EXTENSION_NAME, 'easy_cabinet/main')
    EXTENSION.creator     = 'Bashi'
    EXTENSION.description = 'Parametric kitchen cabinet generator with a control panel, animated doors, handles and toe kicks.'
    EXTENSION.version     = EXTENSION_VERSION
    EXTENSION.copyright   = 'Copyright 2026 Bashi'
    Sketchup.register_extension(EXTENSION, true)
  end
end
