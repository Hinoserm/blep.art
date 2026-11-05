# frozen_string_literal: true

class AddAttemptToE6aiFavoriteImports < ActiveRecord::Migration[8.1]
  def change
    add_column(:e6ai_favorite_imports, :attempt, :integer, null: false, default: 1)
  end
end
