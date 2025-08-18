require 'pry'
require 'aws-sdk-ec2'
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
  # @return [Array<Aws::EC2::Instance>] The last response from an operation that returned instances.
  attr_accessor :client, :ec2_resource, :last_response

  def initialize(region = 'us-east-2')
    @client = Aws::EC2::Client.new(region: region)
    @ec2_resource = Aws::EC2::Resource.new(client: @client)
  end

  # Lists all EC2 instances (optional filters them by tags).
  def list_instances(tags = {})
    response = @ec2_resource.instances
    if response.count.zero?
      puts 'No instances found.'
    else
      unless tags.empty?
        response = response.select do |instance|
          tags.any? { |k, v| instance.tags.any? { |tag| k.to_s.casecmp(tag.key.to_s).zero? && tag.value == v } }
        end
      end
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
  def list_volumes(tags = {})
    response = @ec2_resource.volumes
    if response.count.zero?
      puts 'No volumes found.'
    else
      unless tags.empty?
        response = response.select do |volume|
          tags.any? { |k, v| volume.data.tags.any? { |tag| k.to_s.casecmp(tag.key.to_s).zero? && tag.value == v } }
        end
      end
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
  def modify_volumes(volume_type, iops, dry_run: true)
    modified_count = 0
    if @last_response
      @last_response.each do |volume|
        if volume.is_a?(Aws::EC2::Volume)
          # Modify the volume as needed
          if volume_type != volume.volume_type || (iops && volume.iops != iops)
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
end

binding.pry # rubocop:disable Lint/Debugger
puts 'Done!'
