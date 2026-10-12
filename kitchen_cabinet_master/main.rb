# frozen_string_literal: true

require 'sketchup.rb'
require 'json'

module KitchenCabinetMaster
  PLUGIN_DIR = File.dirname(__FILE__).freeze unless const_defined?(:PLUGIN_DIR)
  DATA_DIR   = File.join(PLUGIN_DIR, 'data').freeze unless const_defined?(:DATA_DIR)
  HTML_DIR   = File.join(PLUGIN_DIR, 'html').freeze unless const_defined?(:HTML_DIR)
  LOADER     = File.join(File.dirname(PLUGIN_DIR), 'kitchen_cabinet_master.rb').freeze unless const_defined?(:LOADER)

  # Load order matters: Response/Defaults first, UI layer last. Loaded with `load`
  # (not `require`) so that installing a newer version over a running one can pick
  # the new code up without restarting SketchUp (see reload_if_updated).
  remove_const(:CODE_FILES) if const_defined?(:CODE_FILES)
  CODE_FILES = %w[
    response defaults attribute_manager validation_manager material_manager catalog_manager
    cabinet_layout appliance_parts fixtures customizer toe_kick part_layout door_animation drawer_animation handle_manager
    front_design panel_generator cabinet_generator part_generator selection_manager snap_manager
    naming_manager placement_manager tag_manager custom_door cabinet_manager part_manager worktop_manager wall_bottom_manager kitchen_planner side_exposure dimensioning dimension_manager live_parts island_hood island_back_panel kitchen_manager path_kitchen cut_list_manager preset_manager customize_manager dialog_manager
  ].freeze

  def self.load_code
    saved = $VERBOSE
    $VERBOSE = nil # constants set again on a reload are not worth a warning
    CODE_FILES.each { |file| load File.join(PLUGIN_DIR, "#{file}.rb") }
  ensure
    $VERBOSE = saved
  end

  load_code
  @code_version = EXTENSION_VERSION

  class << self
    attr_reader :code_version

    # The version written in the extension file on disk right now.
    def disk_version
      File.read(LOADER, encoding: 'UTF-8')[/EXTENSION_VERSION\s*=\s*'([^']+)'/, 1]
    rescue SystemCallError
      nil
    end

    # Installing a newer .rbz over a running one replaces the files on disk, but the
    # old code is still in memory. This loads the new code in its place, and reopens
    # the panel if it was showing, so no restart is needed. Called when the panel is
    # opened and whenever the extension file is loaded again.
    def reload_if_updated
      version = disk_version
      return false if version.nil? || version == @code_version

      reopen = DialogManager.open?
      DialogManager.close
      CustomizeManager.close
      remove_const(:EXTENSION_VERSION) if const_defined?(:EXTENSION_VERSION)
      const_set(:EXTENSION_VERSION, version)
      # Loading main.rb again reloads every code file it lists (a new version may list
      # more files than the old one did) and records the new version.
      saved = $VERBOSE
      begin
        $VERBOSE = nil
        load File.join(PLUGIN_DIR, 'main.rb')
      ensure
        $VERBOSE = saved
      end
      @code_version = version
      DialogManager.show if reopen
      true
    rescue StandardError, ScriptError => e
      warn "[Kitchen Cabinet Master] Could not load the new version: #{e.class}: #{e.message}"
      UI.messagebox("Kitchen Cabinet Master #{version} is installed, but could not be loaded without restarting SketchUp. " \
                    'Please restart SketchUp.')
      false
    end

    # What the menu item and the toolbar button run.
    def open_panel
      reload_if_updated
      DialogManager.show
    end
  end

  unless file_loaded?(__FILE__)
    SelectionManager.install
    SnapManager.install
    menu = UI.menu('Extensions').add_submenu(EXTENSION_NAME)
    menu.add_item('Open Control Panel') { KitchenCabinetMaster.open_panel }
    snap_item = menu.add_item('Snap Moved Cabinets to Neighbours and Walls') { SnapManager.enabled = !SnapManager.enabled? }
    menu.set_validation_proc(snap_item) { SnapManager.enabled? ? MF_CHECKED : MF_UNCHECKED }

    icons = File.join(PLUGIN_DIR, 'icons')
    open_cmd = UI::Command.new('Kitchen Cabinet Master') { KitchenCabinetMaster.open_panel }
    open_cmd.tooltip = 'Kitchen Cabinet Master'
    open_cmd.status_bar_text = 'Open the Kitchen Cabinet Master control panel'
    open_cmd.small_icon = File.join(icons, 'icon_24.png')
    open_cmd.large_icon = File.join(icons, 'icon_32.png')
    toolbar = UI::Toolbar.new(EXTENSION_NAME)
    toolbar.add_item(open_cmd)
    toolbar.show
    file_loaded(__FILE__)
  end
end