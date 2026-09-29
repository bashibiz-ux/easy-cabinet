# frozen_string_literal: true

module KitchenCabinetMaster
  # Every Ruby -> HTML reply uses this shape:
  #   { 'ok' => true/false, 'message' => String, 'data' => Hash, 'errors' => [{ 'field', 'message' }] }
  module Response
    def self.ok(message = '', data = {})
      { 'ok' => true, 'message' => message, 'data' => data, 'errors' => [] }
    end

    def self.fail(message, errors = [])
      { 'ok' => false, 'message' => message, 'data' => {}, 'errors' => errors }
    end
  end
end
