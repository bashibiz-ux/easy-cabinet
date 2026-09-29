# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module KitchenCabinetMaster
  EXTENSION_NAME    = 'Kitchen Cabinet Master'
  EXTENSION_VERSION = '0.11.1'

  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, 'kitchen_cabinet_master/main')
    extension.description = 'Parametric kitchen cabinet generator with a control panel, ' \
                            'animated doors, handles and toe kicks.'
    extension.version   = EXTENSION_VERSION
    extension.creator   = EXTENSION_NAME
    extension.copyright = '2026'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
