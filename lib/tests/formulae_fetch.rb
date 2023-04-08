# frozen_string_literal: true

module Homebrew
  module Tests
    class FormulaeFetch < TestFormulae
      attr_accessor :testing_formulae

      def run!(args:)
        info_header "Testing formulae:"
        puts testing_formulae
        puts

        testing_formulae.each do |formula_name|
          fetch_formula!(formula_name, args: args)
          puts
        end
      end

      private

      def fetch_formula!(formula_name, args:)
        formula = Formula[formula_name]
        tags = formula.bottle_specification.collector.tags

        tags.each do |tag|
          test "brew", "fetch", "--retry", "--formulae", "--bottle-tag=#{tag}", formula_name
        end
      end
    end
  end
end
