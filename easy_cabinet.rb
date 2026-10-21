# frozen_string_literal: true

# Easy Cabinet: registers the extension. The code is in the easy_cabinet folder (see easy_cabinet/main.rb).
module EasyCabinet
  EXTENSION_NAME = 'Easy Cabinet'
  EXTENSION_VERSION = '1.80.0'

  EXTENSION = SketchupExtension.new(EXTENSION_NAME, 'easy_cabinet/main')
  EXTENSION.creator     = 'Bashi'
  EXTENSION.description = 'Parametric kitchen cabinet generator with a control panel, animated doors, handles and toe kicks.'
  EXTENSION.version     = EXTENSION_VERSION
  EXTENSION.copyright   = 'Copyright 2026 Bashi'
  Sketchup.register_extension(EXTENSION, true)
end
