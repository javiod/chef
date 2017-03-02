# @file knife-site-recover.rb
#
# Project Clearwater - IMS in the Cloud
# Copyright (C) 2016  Metaswitch Networks Ltd
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

require_relative 'knife-deployment-utils'
require_relative 'knife-clearwater-utils'
require_relative 'trigger-chef-client'

module ClearwaterKnifePlugins
  class SiteRecover < Chef::Knife
    include ClearwaterKnifePlugins::ClearwaterUtils
    include ClearwaterKnifePlugins::TriggerChefClient

    banner "knife site recover -E ENV --site SITE"

    option :site,
      :long => "--site <site to recover>",
      :description => "Recovers the spcified site",
      :proc => Proc.new { |arg| Integer(arg) rescue begin Chef::Log.error "--site must be an integer"; exit 2 end }

    def run
      Chef::Log.info "Recovering site #{config[:site]} in environment: #{config[:environment]}"

      # Find nodes in the specified site
      nodes = find_nodes(roles: "chef-base", site: config[:site])

      query_string_nodes = nodes.map { |n| "name:#{n.name}" }.join " OR "
      query_string = "chef_environment:#{config[:environment]} AND (#{query_string_nodes})"

      command = "sudo monit start all"

      run_command(config[:cloud], query_string, command)
    end
  end
end