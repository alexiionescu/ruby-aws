# frozen_string_literal: true

require 'aws-sdk-ec2'
require 'aws-sdk-costexplorer'
require 'aws-sdk-s3'
require 'json'
require 'hirb'
Hirb.enable

# This class provides methods to interact with AWS EC2 instances and volumes.
# It uses the AWS SDK for Ruby to perform operations like listing instances,
# listing volumes, and modifying volume attributes.
# Examples: https://github.com/awsdocs/aws-doc-sdk-examples/tree/main/ruby/example_code/ec2
class AwsTasks
  # @!visibility private
  # @return [Aws::EC2::Client] The AWS EC2 client used for API calls.
  # @return [Aws::EC2::Resource] The AWS EC2 resource used for resource-oriented operations.
  # @return [Array<Object>] The last response from an operation that returned Aws objects (Instances, Volumes, etc.).
  attr_accessor :client, :ec2_resource, :last_response, :ce

  def initialize(**options)
    @client = Aws::EC2::Client.new(**options)
    @ec2_resource = Aws::EC2::Resource.new(client: @client)
    @ce = Aws::CostExplorer::Client.new(**options)
  end

  # Filters the response based on the provided tags.
  # @param response [Array<Object>] The response to filter.
  # @param tags [Hash] The tags to filter by.
  # @return [Array<Object>] The filtered response.
  def self.filter_response(response, tags)
    return response if tags.empty?

    response.select do |instance|
      instance.tags.any? do |tag|
        tags.any? do |k, v|
          k.to_s.casecmp(tag.key.to_s).zero? && (
            v.is_a?(Array) ? v.include?(tag.value) : tag.value == v.to_s
          )
        end
      end
    end
  end

  # Lists all EC2 instances (optional filters them by tags).
  #
  # @param tags [Hash<String, String|Array<String>>] Optional tags to filter the instances.
  def list_instances(tags = {})
    response = @ec2_resource.instances
    if response.count.zero?
      puts 'No instances found.'
    else
      response = AwsTasks.filter_response(response, tags)
      puts Hirb::Helpers::Table.render(
        response.map { |instance|
          { id: instance.id, state: instance.state.name, tags: instance.tags.map do |tag|
            "#{tag.key}: #{tag.value}"
          end.join(', ') || 'NoTags' }
        }
      )
      unless tags.empty?
        @last_response = response
        @last_response.count
      end
    end
  rescue StandardError => e
    puts "Error getting information about instances: #{e.message}"
  end

  # Lists all EC2 volumes (optional filters them by tags).
  #
  # @param tags [Hash<String, String|Array<String>>] Optional tags to filter the volumes.
  def list_volumes(tags = {})
    response = @ec2_resource.volumes
    if response.count.zero?
      puts 'No volumes found.'
    else
      response = AwsTasks.filter_response(response, tags)
      puts Hirb::Helpers::Table.render(
        response.map do |volume|
          {
            id: volume.id,
            state: volume.state,
            attached: volume.attachments.map(&:instance_id).join(', ') || 'NoAttachments',
            size: volume.size,
            iops: volume.iops,
            throughput: volume.throughput,
            volume_type: volume.volume_type,
            tags: volume.data.tags.map { |tag| "#{tag.key}: #{tag.value}" }.join(', ') || 'NoTags'
          }
        end,
        fields: %i[id state attached size iops throughput volume_type tags]
      )
    end
    unless tags.empty?
      @last_response = response
      @last_response.count
    end
  rescue StandardError => e
    puts "Error getting information about volumes: #{e.message}"
  end

  # Modifies the volume attributes (type and IOPS) of the last listed volumes (with tag filter)
  #
  # @param volume_type [String] The new volume type (gp2, gp3, etc.)
  # @param iops [Integer] The new IOPS value.
  # @param dry_run [Boolean] Whether to perform a dry run (default: true).
  def modify_volumes(volume_type: nil, iops: nil, dry_run: true)
    modified_count = 0
    if @last_response
      @last_response.each do |volume|
        if volume.is_a?(Aws::EC2::Volume)
          # Modify the volume as needed
          if (volume_type && volume_type != volume.volume_type) || (iops && volume.iops != iops)
            begin
              puts "Modifying volume: #{volume.id} #{dry_run ? '(dry run)' : ''} with type: #{volume_type}, iops: #{iops}"
              @client.modify_volume({ dry_run: dry_run, volume_id: volume.id, volume_type: volume_type, iops: iops })
              modified_count += 1
            rescue StandardError => e
              puts "Error modifying volume #{volume.class} : #{volume.id}: #{e.message}"
            end
          end
        else
          puts "Skipping non-volume object: #{volume.id}.\nPlease run 'list_volumes' with a tags filter before modifying."
        end
      end
    else
      puts "No volumes to modify.\nPlease run 'list_volumes' with a tags filter before modifying."
    end
    modified_count
  end

  def cost_report(regions: [])
    regions = [@ce.config.region] if regions.empty?
    response = @ce.get_cost_and_usage(
      time_period: {
        start: (Date.today - 30).strftime('%Y-%m-%d'),
        end: Date.today.strftime('%Y-%m-%d')
      },
      filter: {
        dimensions: {
          key: 'REGION',
          values: regions
        }
      },
      granularity: 'DAILY',
      group_by: [
        {
          key: 'USAGE_TYPE',
          type: 'DIMENSION'
        }
      ],
      metrics: ['UnblendedCost']
    )
    puts Hirb::Helpers::Table.render(
      response.results_by_time
      .flat_map do |result|
        result.groups
        .select { |group| group.metrics['UnblendedCost'].amount.to_f.round(2).positive? }
        .map do |group|
          {
            date: result.time_period.start,
            usage_type: group.keys.first,
            cost: group.metrics['UnblendedCost'].amount.to_f.round(2)
          }
        end
      end,
      fields: %i[date usage_type cost]
    )
  end
end

# if run with pry: `ruby -rpry script`
if defined?(Pry) && ($PROGRAM_NAME == __FILE__)
  binding.pry # rubocop:disable Lint/Debugger
end
