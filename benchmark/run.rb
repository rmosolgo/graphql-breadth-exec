# frozen_string_literal: true
#
require "debug"
require "graphql"
require "graphql/execution/batching"
require "graphql/batch"
require "graphql/cardinal"

require "benchmark/ips"
require "memory_profiler"
require_relative '../test/fixtures'

class GraphQLBenchmark
  DOCUMENT = GraphQL.parse(BASIC_DOCUMENT)
  CARDINAL_SCHEMA = SCHEMA
  CARDINAL_TRACER = GraphQL::Cardinal::Tracer.new

  class Schema < GraphQL::Schema
    lazy_resolve(Proc, :call)
  end

  class DataloaderSchema < GraphQL::Schema
    use GraphQL::Dataloader
  end

  class BatchLoaderSchema < GraphQL::Schema
    use GraphQL::Batch
  end

  class GemSchema < GraphQL::Schema
    module Node
      include GraphQL::Schema::Interface
      field :id, ID, null: false
    end

    class Metafield < GraphQL::Schema::Object
      field :key, String, null: false, hash_key: "key"
      field :value, String, null: false, hash_key: "value"
    end

    module HasMetafields
      include GraphQL::Schema::Interface
      field :metafield, Metafield do
        argument :key, String
      end
    end

    class Variant < GraphQL::Schema::Object
      field :id, ID, null: false, hash_key: "id"
      field :title, String, null: true, hash_key: "title"
    end

    class VariantConnection < GraphQL::Schema::Object
      field :nodes, [Variant], hash_key: "nodes"
    end

    class Product < GraphQL::Schema::Object
      field :id, ID, null: false, hash_key: "id"
      field :title, String, hash_key: "title"
      field :maybe, String, hash_key: "maybe"
      field :must, String, null: false, hash_key: "must"
      field :metafield, Metafield, hash_key: "metafield" do
        argument :key, String, required: true
      end
      field :variants, VariantConnection, hash_key: "variants", connection: false do
        argument :first, Int
      end
    end

    class ProductConnection < GraphQL::Schema::Object
      field :nodes, [Product], hash_key: "nodes"
    end

    class Query < GraphQL::Schema::Object
      field :products, ProductConnection, hash_key: "products", connection: false do
        argument :first, Int
      end

      field :node, Node, hash_key: "node" do
        argument :id, ID, required: true
      end

      field :nodes, [Node, null: true], hash_key: "nodes" do
        argument :ids, [ID], required: true
      end
    end

    query(Query)
  end

  GRAPHQL_GEM_SCHEMA = Schema.from_definition(SDL, default_resolve: GEM_RESOLVERS)
  GRAPHQL_GEM_LAZY_SCHEMA = Schema.from_definition(SDL, default_resolve: GEM_LAZY_RESOLVERS)
  GRAPHQL_GEM_DATALOADER_SCHEMA = DataloaderSchema.from_definition(SDL, default_resolve: GEM_DATALOADER_RESOLVERS)
  GRAPHQL_GEM_DATALOADER_SCHEMA.use(GraphQL::Dataloader)

  GRAPHQL_GEM_BATCH_LOADER_SCHEMA = BatchLoaderSchema.from_definition(SDL, default_resolve: GEM_BATCH_LOADER_RESOLVERS)
  GRAPHQL_GEM_BATCH_LOADER_SCHEMA.use(GraphQL::Batch)

  class << self
    def benchmark_execution
      default_data_sizes = "10, 100, 1000, 10000"
      sizes = ENV.fetch("SIZES", default_data_sizes).split(",").map(&:to_i)

      with_data_sizes(sizes) do |data_source, num_objects|
        Benchmark.ips do |x|
          x.report("graphql-ruby batching #{num_objects} resolvers") do
            GemSchema.execute_batching(document: DOCUMENT, root_value: data_source, validate: false)
          end

          x.report("graphql-ruby: #{num_objects} resolvers") do
            GemSchema.execute(document: DOCUMENT, root_value: data_source, validate: false)
          end

          x.report("graphql-cardinal #{num_objects} resolvers") do
            GraphQL::Cardinal::Executor.new(
              SCHEMA,
              BREADTH_RESOLVERS,
              DOCUMENT,
              data_source,
              tracers: [CARDINAL_TRACER],
            ).perform
          end

          x.compare!
        end
      end
    end

    def benchmark_lazy_execution
      default_data_sizes = "10, 100, 1000, 10000"
      sizes = ENV.fetch("SIZES", default_data_sizes).split(",").map(&:to_i)

      with_data_sizes(sizes) do |data_source, num_objects|
        Benchmark.ips do |x|
          x.report("graphql-ruby lazy: #{num_objects} resolvers") do
            GRAPHQL_GEM_LAZY_SCHEMA.execute(document: DOCUMENT, root_value: data_source)
          end

          x.report("graphql-ruby dataloader: #{num_objects} resolvers") do
            GRAPHQL_GEM_DATALOADER_SCHEMA.execute(document: DOCUMENT, root_value: data_source)
          end

          x.report("graphql-ruby batch: #{num_objects} resolvers") do
            GRAPHQL_GEM_BATCH_LOADER_SCHEMA.execute(document: DOCUMENT, root_value: data_source)
          end

          x.report("graphql-cardinal: #{num_objects} lazy resolvers") do
            GraphQL::Cardinal::Executor.new(
              SCHEMA,
              BREADTH_DEFERRED_RESOLVERS,
              DOCUMENT,
              data_source,
              tracers: [CARDINAL_TRACER],
            ).perform
          end

          x.compare!
        end
      end
    end

    def benchmark_introspection
      document = GraphQL.parse(GraphQL::Introspection.query)

      Benchmark.ips do |x|
        x.report("graphql-ruby: introspection") do
          GRAPHQL_GEM_SCHEMA.execute(document: document)
        end

        x.report("graphql-cardinal introspection") do
          GraphQL::Cardinal::Executor.new(
            SCHEMA,
            BREADTH_RESOLVERS,
            document,
            {},
            tracers: [CARDINAL_TRACER],
          ).perform
        end

        x.compare!
      end
    end

    def memory_profile
      default_data_sizes = "10, 1000"
      sizes = ENV.fetch("SIZES", default_data_sizes).split(",").map(&:to_i)

      with_data_sizes(sizes) do |data_source, num_objects|
        report = MemoryProfiler.report do
          GRAPHQL_GEM_SCHEMA.execute(document: DOCUMENT, root_value: data_source)
        end

        puts "\n\ngraphql-ruby memory profile: #{num_objects} resolvers"
        puts "=" * 50
        report.pretty_print
      end

      with_data_sizes(sizes) do |data_source, num_objects|
        report = MemoryProfiler.report do
          GraphQL::Cardinal::Executor.new(
            SCHEMA,
            BREADTH_RESOLVERS,
            DOCUMENT,
            data_source,
            tracers: [CARDINAL_TRACER],
          ).perform
        end

        puts "\n\ngraphql-cardinal memory profile: #{num_objects} resolvers"
        puts "=" * 50
        report.pretty_print
      end
    end

    def with_data_sizes(sizes = [10])
      sizes.each do |size|
        products = (1..size).map do |i|
          {
            "id" => i.to_s,
            "title" => "Product #{i}",
            "variants" => {
              "nodes" => (1..5).map do |j|
                {
                  "id" => "#{i}-#{j}",
                  "title" => "Variant #{j}"
                }
              end
            }
          }
        end

        data = {
          "products" => {
            "nodes" => products
          }
        }

        num_objects = object_count(data)

        yield data, num_objects
      end
    end

    def object_count(obj)
      case obj
      when Hash
        obj.size + obj.values.sum { |value| object_count(value) }
      when Array
        obj.sum { |item| object_count(item) }
      else
        0
      end
    end
  end
end
