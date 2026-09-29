# Kitchen Cabinet Generator - SketchUp Ruby Extension
require 'sketchup.rb'
require 'extensions.rb'

module KitchenCabinet
  EXTENSION_NAME = 'Kitchen Cabinet Generator'
  VERSION = '1.0.0'
  ROOT = File.dirname(__FILE__)
  
  unless file_loaded?(__FILE__)
    extension = SketchupExtension.new(EXTENSION_NAME, File.join(ROOT, 'kitchen_cabinet', 'main.rb'))
    extension.description = 'Parametric kitchen cabinet generator with HTML controls, live editing and door animation.'
    extension.version = VERSION
    extension.creator = 'OpenAI'
    Sketchup.register_extension(extension, true)
    file_loaded(__FILE__)
  end
end
