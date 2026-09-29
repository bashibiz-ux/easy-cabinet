require 'sketchup.rb'
require 'json'
require_relative 'cabinet_generator'
require_relative 'cabinet_manager'
require_relative 'ui_controller'

module KitchenCabinet
  def self.start
    @manager ||= CabinetManager.new
    @ui ||= UIController.new(@manager)
    @manager.ui = @ui
    @ui.show
  end

  unless file_loaded?(__FILE__)
    menu = UI.menu('Extensions').add_item('Kitchen Cabinet Generator') { KitchenCabinet.start }
    toolbar = UI::Toolbar.new('Kitchen Cabinet Generator')
    cmd = UI::Command.new('Kitchen Cabinet Generator') { KitchenCabinet.start }
    cmd.tooltip = 'Open Kitchen Cabinet Generator'
    cmd.status_bar_text = 'Create and edit parametric kitchen cabinets'
    toolbar.add_item(cmd)
    toolbar.show
    file_loaded(__FILE__)
  end
end
