# frozen_string_literal: true

# The extension is called Easy Cabinet now (easy_cabinet.rb and the easy_cabinet folder). This file has the name of the loader it had before: installing over an old
# version replaces that one with this, which takes the old folder, no longer used, away and does nothing else.
require 'fileutils'

begin
  old_folder = File.join(File.dirname(__FILE__), 'kitchen_cabinet_master')
  FileUtils.rm_rf(old_folder) if File.file?(File.join(old_folder, 'main.rb'))
rescue StandardError
  nil # (a file in it is in use: it goes at the next start)
end
