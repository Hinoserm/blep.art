# frozen_string_literal: true

class CreateE6aiFavoriteImports < ActiveRecord::Migration[8.1]
  def change
    create_table(:e6ai_favorite_imports) do |t|
      t.references(:user, null: false, foreign_key: true, index: { unique: true })
      t.integer(:e6ai_user_id, null: false)
      t.string(:status, null: false, default: "queued")
      t.string(:source)
      t.string(:error)
      t.integer(:expected_count)
      t.integer(:pages_fetched, null: false, default: 0)
      t.integer(:found_count, null: false, default: 0)
      t.integer(:imported_count, null: false, default: 0)
      t.integer(:already_count, null: false, default: 0)
      t.integer(:missing_count, null: false, default: 0)
      t.integer(:over_limit_count, null: false, default: 0)
      t.timestamps
    end
  end
end
