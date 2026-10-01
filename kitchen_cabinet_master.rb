# frozen_string_literal: true

require 'sketchup.rb'
require 'extensions.rb'

module KitchenCabinetMaster
  EXTENSION_NAME = 'Kitchen Cabinet Master' unless const_defined?(:EXTENSION_NAME)

  # Set again on every load, so installing a newer version over a running one is
  # noticed (see KitchenCabinetMaster.reload_if_updated in main.rb).
  remove_const(:EXTENSION_VERSION) if const_defined?(:EXTENSION_VERSION)
  EXTENSION_VERSION = '0.24.0'

  if file_loaded?(__FILE__)
    # Loaded again after an install or update: swap in the new code, no restart needed.
    KitchenCabinetMaster.reload_if_updated if KitchenCabinetMaster.respond_to?(:reload_if_updated)
  else
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