# frozen_string_literal: true

require "rails_helper"

# Collections that can't estimate their size keep the old "assume it's huge" behaviour.
RSpec.describe Danbooru::Paginator::BaseExtension do
  let(:klass) do
    Class.new do
      include Danbooru::Paginator::BaseExtension

      def paginate_numbered = self

      def real_count = raise("real_count should not be called for an unsearched page")
    end
  end

  it "assumes 1,000,000 rows for an unsearched page when the collection can't estimate" do
    expect(klass.new.paginate("1", limit: 10, search_count: nil).total_count).to eq(1_000_000)
  end
end
