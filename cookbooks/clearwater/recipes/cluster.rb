# @file cluster.rb
#
# Project Clearwater - IMS in the Cloud
# Copyright (C) 2013  Metaswitch Networks Ltd
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, either version 3 of the License, or (at your
# option) any later version, along with the "Special Exception" for use of
# the program along with SSL, set forth below. This program is distributed
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;
# without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more
# details. You should have received a copy of the GNU General Public
# License along with this program.  If not, see
# <http://www.gnu.org/licenses/>.
#
# The author can be reached by email at clearwater@metaswitch.com or by
# post at Metaswitch Networks Ltd, 100 Church St, Enfield EN2 6BQ, UK
#
# Special Exception
# Metaswitch Networks Ltd  grants you permission to copy, modify,
# propagate, and distribute a work formed by combining OpenSSL with The
# Software, or a work derivative of such a combination, even if such
# copying, modification, propagation, or distribution would otherwise
# violate the terms of the GPL. You must comply with the GPL in all
# respects for all of the code used other than OpenSSL.
# "OpenSSL" means OpenSSL toolkit software distributed by the OpenSSL
# Project and licensed under the OpenSSL Licenses, or a work based on such
# software and licensed under the OpenSSL Licenses.
# "OpenSSL Licenses" means the OpenSSL License and Original SSLeay License
# under which the OpenSSL Project distributes the OpenSSL toolkit software,
# as those licenses appear in the file LICENSE-OPENSSL.

# We need the Cassandra-CQL gem later, install it as a pre-requisite.
build_essential_action = apt_package "build-essential" do
  action :nothing
end
build_essential_action.run_action(:install)

chef_gem "cassandra-cql" do
  action :install
  source "https://rubygems.org"
end

# Work out whether we're geographically-redundant.  In this case, we'll need to
# configure things to use public IP addresses rather than local.
gr_environments = node[:clearwater][:gr_environments] || [node.chef_environment]
is_gr = (gr_environments.length > 1)

# Clustering for Sprout nodes.
if node.run_list.include? "role[sprout]"

  def update_memstore_settings(environment, template_file, file)

    # Get the full list of sprout nodes, in index order.
    sprouts = search(:node,
                     "role:sprout AND chef_environment:#{environment}")
    sprouts.sort_by! { |n| n[:clearwater][:index] }

    # Strip this down to the list of sprouts that have already joined the cluster
    # and the list that are not quiescing sprouts
    joined = sprouts.find_all { |s| not s[:clearwater][:joining] }
    nonquiescing = sprouts.find_all { |s| not s[:clearwater][:quiescing] }

    if joined.size == sprouts.size and nonquiescing.size == sprouts.size
      # Cluster is stable, so just include the server list.
      servers = sprouts
      new_servers = []
    else
      # Cluster is growing or shrinking, so use the joined list as the servers
      # list and the nonquiescing list as the new servers list.
      servers = joined
      new_servers = nonquiescing
    end

    template file do
      source template_file
      mode 0644
      owner "root"
      group "root"
      notifies :reload, "service[sprout]", :immediately
      variables servers: servers,
                new_servers: new_servers
    end
  end

  # Update cluster_settings for local registration store.
  update_memstore_settings(node.chef_environment,
                           "cluster/cluster_settings.erb",
                           "/etc/clearwater/cluster_settings")

  other_gr_environments = gr_environments.reject { |e| e == node.chef_environment }
  if !other_gr_environments.empty?
    update_memstore_settings(other_gr_environments[0],
                             "cluster/remote_cluster_settings.erb",
                             "/etc/clearwater/remote_cluster_settings")
  end

  service "sprout" do
    supports :reload => true
    action :nothing
  end

  ruby_block "set_clustered" do
    block do
      node.set["clustered"] = true
      node.save
    end
    action :nothing
  end
end

# Support clustering for homer and homestead
if node.roles.include? "cassandra"
  node_type = if node.run_list.include? "role[homer]"
                "homer"
              elsif node.run_list.include? "role[homestead]"
                "homestead"
              end
  cluster_name = node_type.capitalize + "Cluster"

  # Work out the other nodes in the geo-redundant cluster - we'll list all these
  # nodes as seeds.
  gr_environment_search = gr_environments.map { |e| "chef_environment:" + e }.join(" OR ")
  gr_cluster_nodes = search(:node, "role:#{node_type} AND (#{gr_environment_search})")

  puts gr_cluster_nodes
  puts gr_cluster_nodes.select {|n| not (n[:clearwater].nil? or n[:clearwater][:cassandra].nil? or n[:clearwater][:cassandra][:cluster].nil?) }
  seeds = gr_cluster_nodes.select {|n| not (n[:clearwater].nil? or n[:clearwater][:cassandra].nil? or n[:clearwater][:cassandra][:cluster].nil?) }.map { |n| is_gr ? n.cloud.public_ipv4 : n.cloud.local_ipv4 }
  if seeds.empty?
    seeds = gr_cluster_nodes.map { |n| is_gr ? n.cloud.public_ipv4 : n.cloud.local_ipv4 }
  end
  # Create the Cassandra config and topology files
  template "/etc/cassandra/cassandra.yaml" do
    source "cassandra/cassandra.yaml.erb"
    mode "0644"
    owner "root"
    group "root"
    variables cluster_name: cluster_name,
              seeds: seeds,
              node: node,
              is_gr: is_gr
  end

  template "/etc/cassandra/cassandra-topology.properties" do
    source "cassandra/cassandra-topology.properties.erb"
    mode "0644"
    owner "root"
    group "root"
    variables gr_cluster_nodes: gr_cluster_nodes,
              is_gr: is_gr
  end

  template "/etc/cassandra/cassandra-env.sh" do
    source "cassandra/cassandra-env.sh.erb"
    mode "0644"
    owner "root"
    group "root"
  end

  if not node[:clearwater].include? 'quiescing'
    if not tagged?('clustered')
      # Node has never been clustered, clean up old state then restart Cassandra into the new cluster
      execute "monit" do
        command "monit unmonitor cassandra"
        user "root"
        action :run
      end

      service "cassandra" do
        pattern "jsvc.exec"
        service_name "cassandra"
        action :stop
      end

      directory "/var/lib/cassandra" do
        recursive true
        action :delete
      end

      directory "/var/lib/cassandra" do
        action :create
        mode "0755"
        owner "cassandra"
        group "cassandra"
      end

      # Restart Cassandra, making sure not to nice it.
      execute "start cassandra" do
        command "nice -n $((-$(nice))) service cassandra start"
        user "root"
        action :run
      end

      # It's possible that we might need to create the keyspace now.
      ruby_block "create keyspace and tables" do
        block do
          require 'cassandra-cql'

          # Cassandra takes some time to come up successfully, give it 1 minute (should be ample)
          db = nil
          60.times do
            begin
              db = CassandraCQL::Database.new('127.0.0.1:9160')
              break
            rescue ThriftClient::NoServersAvailable
              sleep 1
            end
          end

          fail "Cassandra failed to start in the cluster" unless db

          # Create the KeySpace and table(s), don't care if they already exist.
          #
          # For all of these requests, it's possible that the creating a
          # keyspace/table might take so long that the thrift client times out.
          # This seems to happen a lot when Cassandra has just booted, probably
          # it's still settling down or garbage collecting.  In any case, on a
          # transport exception we'll simply sleep for a second and retry.  The
          # interesting case is an InvalidRequest which means that the
          # keyspace/table already exists and we should stop trying to create it.
          #
          # These create statements must match the statements defined in the crest
          # project.
          if node_type == "homer"
            cql_cmds = ["CREATE KEYSPACE homer WITH REPLICATION = {'class': 'SimpleStrategy', 'replication_factor': 2}",
                        "USE homer",
                        "CREATE TABLE simservs (user text PRIMARY KEY, value text) WITH read_repair_chance = 1.0"]
          elsif node_type == "homestead"
            cql_cmds = ["CREATE KEYSPACE homestead_cache WITH REPLICATION =  {'class': 'SimpleStrategy', 'replication_factor': 2};",
                        "USE homestead_cache;",
                        "CREATE TABLE impi (private_id text PRIMARY KEY, digest_ha1 text, digest_realm text, digest_qop text, known_preferred boolean) WITH read_repair_chance = 1.0;",
                        "CREATE TABLE impu (public_id text PRIMARY KEY, ims_subscription_xml text) WITH read_repair_chance = 1.0;",
                        "CREATE KEYSPACE homestead_provisioning WITH REPLICATION =  {'class' : 'SimpleStrategy', 'replication_factor' : 2};",
                        "USE homestead_provisioning;",
                        "CREATE TABLE implicit_registration_sets (id uuid PRIMARY KEY, dummy text) WITH read_repair_chance = 1.0;",
                        "CREATE TABLE service_profiles (id uuid PRIMARY KEY, irs text, initialfiltercriteria text) WITH read_repair_chance = 1.0;",
                        "CREATE TABLE public (public_id text PRIMARY KEY, publicidentity text, service_profile text) WITH read_repair_chance = 1.0;",
                        "CREATE TABLE private (private_id text PRIMARY KEY, digest_ha1 text) WITH read_repair_chance = 1.0;"]
          end

          cql_cmds.each do |cql_cmd|
            begin
              puts "CQL command: " + cql_cmd
              db.execute(cql_cmd)
              # Pause briefly to ensure each command settles in time.
              sleep 5
            rescue CassandraCQL::Thrift::Client::TransportException, CassandraCQL::Thrift::SchemaDisagreementException => e
              puts "Failure! Sleeping and retrying."
              sleep 1
              retry
            rescue CassandraCQL::Error::InvalidRequestException
              # Pass
            end
          end
        end

        # To prevent conflicts during clustering, only homestead-1 or homer-1
        # will ever attempt to create Keyspaces.
        only_if { node[:clearwater][:index] == 1 }
        action :run
      end

      # Re-enable monitoring
      execute "monit" do
        command "monit monitor cassandra"
        user "root"
        action :run
      end
    end

    # Now we've migrated to our new token, remember it
    ruby_block "save cluster details" do
      block do
        node.set[:clearwater][:cassandra][:cluster] = cluster_name
      end
      action :run
    end
  end

  # Now we're clustered
  tag('clustered')
end
