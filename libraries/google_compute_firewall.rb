# frozen_string_literal: true

require 'gcp_backend'

module Inspec::Resources
  class GoogleComputeFirewall < GcpResourceBase
    name 'google_compute_firewall'
    desc 'Verifies settings for a compute firewall rule'

    example "
      describe google_compute_firewall(project: 'chef-inspec-gcp', name: 'gcp-inspec-test') do
        it { should exist }
        its('name') { should eq 'inspec-test' }
        its('status') { should eq 'in_use' }
        ...
      end
    "
    def initialize(opts = {})
      # Call the parent class constructor
      super(opts)
      @display_name = opts[:name]
      catch_gcp_errors do
        @firewall = @gcp.gcp_compute_client.get_firewall(opts[:project], opts[:name])
        create_resource_methods(@firewall)
      end
    end

    # Check whether the firewall rule allows HTTP access (tcp ingress on port 80)
    def allowed_http?
      port_protocol_allowed('80')
    end

    # Check whether the firewall rule allows SSH access (tcp ingress on port 22)
    def allowed_ssh?
      port_protocol_allowed('22')
    end

    def allowed_https?
      port_protocol_allowed('443')
    end

    def allowed_rdp?
      port_protocol_allowed('3389')
    end

    def allow_port_protocol?(port, protocol)
      port_protocol_allowed(port, protocol)
    end
    RSpec::Matchers.alias_matcher :allow_port_protocol, :be_allow_port_protocol

    # initial implementation allows to search for target source and destination tags - can
    # filter plural firewalls based on direction to pin down the desired rules and choose the appropriate method
    # see similar below example for ip_range_list
    def allow_source_tags?(tag_list)
      return false if !defined?(source_tags) || source_tags.nil?
      match_list_helper(source_tags, tag_list)
    end
    RSpec::Matchers.alias_matcher :allow_source_tags, :be_allow_source_tags

    def allow_target_tags?(tag_list)
      return false if !defined?(target_tags) || target_tags.nil?
      match_list_helper(target_tags, tag_list)
    end
    RSpec::Matchers.alias_matcher :allow_target_tags, :be_allow_target_tags

    def allow_source_tags_only?(tag_list)
      return false if !defined?(source_tags) || source_tags.nil?
      match_list_helper(source_tags, tag_list, true)
    end
    RSpec::Matchers.alias_matcher :allow_source_tags_only, :be_allow_source_tags_only

    def allow_target_tags_only?(tag_list)
      return false if !defined?(target_tags) || target_tags.nil?
      match_list_helper(target_tags, tag_list, true)
    end
    RSpec::Matchers.alias_matcher :allow_target_tags_only, :be_allow_target_tags_only

    def match_list_helper(source_list, target_list, only = false)
      # helps streamline matching exact equality versus inclusion of target and source lists
      return source_list.sort == target_list.sort if only # i.e. exact equality
      # check the source list includes at least all specified target list elements
      target_list.each do |must_be_present|
        return false if !source_list.include? must_be_present
      end
      true
    end

    # initial implementation is direction agnostic and treats IP ranges separately
    # Can revisit in the future to include AWS style matchers such as allow_in/out with multiple criteria
    # including protocols/ports for example
    def allow_ip_ranges_only?(ip_range_list)
      allow_ip_range_list(ip_range_list, true)
    end
    RSpec::Matchers.alias_matcher :allow_ip_ranges_only, :be_allow_ip_ranges_only

    def allow_ip_ranges?(ip_range_list)
      allow_ip_range_list(ip_range_list)
    end
    RSpec::Matchers.alias_matcher :allow_ip_ranges, :be_allow_ip_ranges

    def allow_ip_range_list(ip_range_list, only = false)
      raise Inspec::Exceptions::ResourceFailed, "google_compute_firewall is missing expected property 'direction'" if !defined?(direction) || direction.nil?
      # the intention here is for firewall rules plural to be filtered based on direction, then tested for particular IP ranges
      # e.g.        describe google_compute_firewalls(project: 'chef-inspec-gcp').where(firewall_direction: 'INGRESS').firewall_names.each do |firewall_name| do
      #               describe google_compute_firewall(project: 'chef-inspec-gcp',  name: firewall_name) do
      #                 it { should_not allow_ip_ranges ["0.0.0.0/0"] }
      #               end
      #             end
      # direction affects what the property is e.g. INGRESS->source_ranges, EGRESS->destination_ranges
      ranges = nil
      if direction == 'INGRESS'
        return false if !defined?(source_ranges) || source_ranges.nil?
        ranges = source_ranges
      else
        return false if !defined?(destination_ranges) || destination_ranges.nil?
        ranges = destination_ranges
      end
      return false if !defined?(ranges) || ranges.nil?
      # so now we have a list of IP addresses to compare
      match_list_helper(ranges, ip_range_list, only)
    end

    # note that port_list only accepts individual ports to match, not ranges
    def port_protocol_allowed(single_port, protocol = 'tcp')
      raise Inspec::Exceptions::ResourceFailed, "google_compute_firewall is missing expected property 'allowed'" if !defined?(allowed) || allowed.nil?
      # "allowed" can have several port/protocol pairing entries e.g. tcp:80 or udp:4000-5000
      # first, let's find the matching protocol indexes to compare against
      protocol_match_indexes = []
      allowed.each_with_index do |rule, index|
        next if rule.item[:ip_protocol].nil?
        protocol_match_indexes<<index if rule.item[:ip_protocol]==protocol
      end
      # Now we know the list of matching protocol entries to check against.
      # Note the syntax for protocol port definitions versus what we see here is:
      # "tcp:80" -> "tcp" ["80"]
      # "tcp:90,91" -> "tcp:90", "tcp:91" -> "tcp" ["90","91"]
      # "udp:3000-4000" -> "udp" ["3000-4000"] # can also potentially include single port combinations in the list for a single rule here
      # We now check for a match based on each of the above cases
      protocol_match_indexes.each do |protocol_index|
        # there can be multiple protocol rules for different ports etc. ["22"] or ["123-126"]
        ports_in_rule = allowed[protocol_index].item[:ports]
        next if ports_in_rule.nil?
        ports_in_rule.each do |rule_port|
          return true if single_port_matches(rule_port, single_port)
        end
      end
      false
    end

    def single_port_matches(rule_port, single_port)
      # if '-' in there it means we should check each provided port for existence in a range
      if !rule_port.include? '-'
        # simplest case, only one port string specified
        return true if rule_port==single_port
        # if not, no match
      else
        # the rule_port here is a range such as "4000-5000", protect against any non-integer input by checking for nil values
        upper_limit = rule_port.split('-')[1].to_i
        lower_limit = rule_port.split('-')[0].to_i
        raise Inspec::Exceptions::ResourceFailed, "google_compute_firewall unexpected port range specified: '#{rule_port}'" if upper_limit.nil? || lower_limit.nil?
        return true if single_port.to_i.between?(lower_limit, upper_limit)
        # if not, no match
      end
      false
    end

    def exists?
      !@firewall.nil?
    end

    def to_s
      "Firewall Rule #{@display_name}"
    end
  end
end
