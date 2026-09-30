# frozen_string_literal: true

require 'json'

module KitchenCabinetMaster
  # Central place for default values. All lengths are millimetres; angles are degrees.
  module Defaults
    # Toe-kick material choices that follow another part instead of naming a material.
    SAME_AS_DOOR    = '__door__'
    SAME_AS_CARCASS = '__carcass__'
    SAME_AS_CABINET = '__cabinet__' # stored by older versions; it means "same as door material"

    CATEGORIES = [
      { 'id' => 'base', 'name' => 'Base Unit' },
      { 'id' => 'wall', 'name' => 'Wall Unit' },
      { 'id' => 'tall', 'name' => 'Tall Unit' },
      { 'id' => 'corner', 'name' => 'Corner Unit' }
    ].freeze

    # Cabinet widths offered in the "Standard Width" list (mm). Picking one fills
    # the Width field, which stays editable for any other size.
    STANDARD_WIDTHS = [300, 350, 400, 450, 500, 600, 700, 800, 900, 1000, 1200].freeze

    DIRECTIONS = [
      { 'id' => 'left',  'name' => 'Left' },
      { 'id' => 'right', 'name' => 'Right' }
    ].freeze

    # The plain white a cabinet, filler, end panel or toe kick gets when no
    # material has been chosen (a preset in data/materials.json, created on first use).
    DEFAULT_MATERIAL = 'White'

    # Cabinet names are the unit code plus the width: BU600, WU800, TU600 ...
    # A catalog cabinet can set its own "code"; otherwise its category decides.
    NAME_PREFIXES = { 'base' => 'BU', 'wall' => 'WU', 'tall' => 'TU', 'corner' => 'CR', 'filler' => 'FIL',
                      'end_panel' => 'EP', 'toe_kick' => 'TK' }.freeze

    # Standalone parts: not full cabinets (see PartLayout, PartGenerator, PartManager).
    # Fillers and end panels take up their own footprint in the model; a toe kick
    # stands under the cabinets' fronts and never blocks anything.
    PART_KINDS = %w[filler end_panel toe_kick].freeze
    END_PANEL_SIDES = %w[left right].freeze


    # ---- handles ----------------------------------------------------------------
    # A bundle file (data/handles/*.json) names a profile and lists the lengths and
    # finishes it offers. "length" is the bar length, or the diameter of a knob.
    HANDLE_PROFILES = %w[bar knob].freeze

    HANDLE_ORIENTATIONS = [
      { 'id' => 'vertical',   'name' => 'Vertical' },
      { 'id' => 'horizontal', 'name' => 'Horizontal' }
    ].freeze

    # Top / Center / Bottom sit on the free-edge side of a hinged door; Left / Right
    # sit on that side edge, vertically centred; Custom uses exact coordinates.
    HANDLE_POSITIONS = [
      { 'id' => 'top',    'name' => 'Top' },
      { 'id' => 'center', 'name' => 'Center' },
      { 'id' => 'bottom', 'name' => 'Bottom' },
      { 'id' => 'left',   'name' => 'Left' },
      { 'id' => 'right',  'name' => 'Right' },
      { 'id' => 'custom', 'name' => 'Custom' }
    ].freeze

    # Used when a bundle does not say otherwise. Offsets are the clear distance (mm)
    # from the door edge to the nearest edge of the handle.
    HANDLE_DEFAULTS = {
      'orientation'     => 'vertical',
      'position'        => 'top',
      'side_offset'     => 35.0,
      'vertical_offset' => 80.0,
      'custom_x'        => 50.0, # from the door's left edge to the handle centre
      'custom_z'        => 100.0 # from the door's bottom edge to the handle centre
    }.freeze
    HANDLE_SECTION = 10.0    # bar cross-section
    HANDLE_PROJECTION = 30.0 # distance from the door face to the outer face of the grip

    # Component definitions this extension creates are named after what they are
    # (BU600, BU600 Carcass, Panel 18 x 560 x 780 ...) and carry a "managed" marker
    # attribute so they can be recognised and cleaned up. Older versions instead
    # prefixed the name with "KCM "; those are still recognised.
    LEGACY_DEFINITION_PREFIX = 'KCM '

    # Carcass construction rules (mm). Not user parameters; a future catalog
    # could override them per cabinet type.
    BACK_RECESS          = 10.0  # back panel is set this far in from the rear edge of the sides
    RAIL_DEPTH           = 100.0 # depth of the two structural rails that top a base unit
    SHELF_FRONT_SETBACK  = 20.0  # shelves stop this far short of the carcass front
    SHELF_SIDE_CLEARANCE = 1.0   # gap each side of a shelf so it can be removed
    TOE_KICK_RECESS      = 50.0  # the toe kick is set back this far from the carcass front
    DOOR_CLEARANCE       = 2.0   # doors stand this far in front of the carcass

    PARAMS = {
      'catalog_id'             => '',
      'cabinet_category'       => 'base',
      'cabinet_type'           => '',
      'handle_id'              => '',
      # Blank = use the bundle's own default. The numeric handle values
      # (length, offsets, custom position) only appear once they are set.
      'handle_finish'          => '',
      'handle_material'        => '', # blank = the material of the chosen finish
      'handle_orientation'     => '',
      'handle_position'        => '',

      'base_material'          => DEFAULT_MATERIAL,
      'wall_material'          => DEFAULT_MATERIAL,
      'tall_material'          => DEFAULT_MATERIAL,
      'cabinet_material'       => '',
      'carcass_material'       => '', # blank = the carcass follows the door material
      'material_thickness'     => 18.0,
      'back_thickness'         => 6.0,

      'door_opening_direction' => 'left',
      'door_opening_angle'     => 90.0,
      'show_opening_direction' => true, # the plan symbol on the floor
      'show_door_symbol'       => true, # the dashed swing lines on the door
      'door_gap'               => 1.5,
      'door_reveal'            => 2.0,

      'placement_gap'          => 0.0,
      'shelf_count'            => 1,

      'toe_kick_height'        => 100.0,
      'toe_kick_thickness'     => 18.0,
      'toe_kick_material'      => SAME_AS_DOOR,
      'toe_kick_piece_length'  => 600.0,

      'visibility_settings'    => { 'carcass' => true, 'door' => true, 'toe_kick' => true }
    }.freeze

    # A filler: a flat board beside a cabinet, on its wall side, with its front face
    # flush with the door. `width` is how wide the gap it fills is, `thickness` how
    # thick the board is (front to back). Its height and how far it stands off the
    # floor follow the cabinet it is inserted against (the height field only
    # starts out as that cabinet's height). It has no material of its own: it
    # always takes the door material of that cabinet.
    FILLER_PARAMS = {
      'width'     => 100.0,
      'thickness' => 18.0,
      'height'    => 780.0
    }.freeze

    # A toe kick: a run of `toe_kick_pieces` pieces, each `toe_kick_piece_length`
    # long, laid end to end. `toe_kick_recess` is how far its front is set back
    # from the carcass front.
    TOE_KICK_PARAMS = {
      'toe_kick_height'       => 100.0,
      'toe_kick_thickness'    => 18.0,
      'toe_kick_material'     => SAME_AS_DOOR,
      'toe_kick_piece_length' => 600.0,
      'toe_kick_pieces'       => 1,
      'toe_kick_recess'       => TOE_KICK_RECESS
    }.freeze
    DEFAULT_TOE_KICK_DEPTH = 560.0 # carcass depth assumed when no cabinet is selected

    # An end panel: which side of the currently selected cabinet/filler it goes
    # on, how thick it is, and its material. Its width, height and depth all
    # follow the target (see PartLayout.end_panel). The material starts as "same
    # as door material" and follows the door until one is picked by hand.
    END_PANEL_PARAMS = {
      'side'      => 'left',
      'thickness' => 18.0,
      'material'  => SAME_AS_DOOR
    }.freeze

    # Returns a deep, mutable copy so callers can modify it freely.
    def self.params
      JSON.parse(JSON.generate(PARAMS))
    end

    def self.filler_params
      JSON.parse(JSON.generate(FILLER_PARAMS))
    end

    def self.end_panel_params
      JSON.parse(JSON.generate(END_PANEL_PARAMS))
    end

    def self.toe_kick_params
      JSON.parse(JSON.generate(TOE_KICK_PARAMS))
    end

    def self.category_ids
      CATEGORIES.map { |c| c['id'] }
    end

    def self.direction_ids
      DIRECTIONS.map { |d| d['id'] }
    end

    def self.handle_orientation_ids
      HANDLE_ORIENTATIONS.map { |o| o['id'] }
    end

    def self.handle_position_ids
      HANDLE_POSITIONS.map { |o| o['id'] }
    end
  end
end
