#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
# Copyright © 2012 Diego Elio Pettenò <flameeyes@flameeyes.eu>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND INTERNET SOFTWARE CONSORTIUM DISCLAIMS
# ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL INTERNET SOFTWARE
# CONSORTIUM BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
# DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
# PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS
# ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS
# SOFTWARE.

require 'inifile'
require 'aws'
require 'archive/tar/minitar'
require 'builder'

match = Regexp.new("( .*\\*.* ERROR: .*failed|detected file collision|Tinderbox QA Warning!|QA Notice: (Pre-stripped|file does not exist|command not found|USE flag|Files built without respecting LDFLAGS|The following files)|linux_config_exists|will always overflow|called with bigger|maintainer mode detected|econf called in src_compile)")

config = IniFile.new("./tboxanalysis.ini")

s3 = AWS::S3.new(:access_key_id => config['aws']['access_key'],
                 :secret_access_key => config['aws']['secret_key'])

bucket_name = config['aws']['bucket']
bucket = s3.buckets[bucket_name]
s3.buckets.create(bucket_name) unless bucket.exists?

unless bucket.objects['htmlgrep.css']
  bucket.objects.create('htmlgrep.css',
                        :file => 'htmlgrep.css',
                        :acl => :public_read,
                        :content_type => "text/css",
                        :storage_class => :reduced_redundancy)
end

sdb = AWS::SimpleDB.new(:access_key_id => config['aws']['access_key'],
                        :secret_access_key => config['aws']['secret_key'])

domain_name = config['aws']['domain']
domain = sdb.domains[domain_name]
sdb.domains.create(domain_name) unless domain.exists?

Archive::Tar::Minitar::Reader.open($stdin) do |input|
  input.each do |log|
    matches = 0

    next unless log.file?

    log_name  = File.basename(log.name, ".log")

    xml_builder = Builder::XmlMarkup.new(:indent => 2)
    xml_builder.instruct!

    html_output = xml_builder.html {
      xml_builder.head {
        xml_builder.link(:href => "htmlgrep.css",
                        :rel => "stylesheet",
                        :type => "text/css")
      }

      xml_builder.body {
        xml_builder.ol {
          log.read.split("\n").each do |line|
            if line =~ match
              xml_builder.li line, :class => "match"
              matches += 1
            else
              xml_builder.li line
            end
          end
        }
      }
    }

    html_log = bucket.objects.create(log_name + ".html",
                                     :data => html_output,
                                     :acl => :public_read,
                                     # if we don't use text/html Chromium is
                                     # unable to render it with the CSS.
                                     :content_type => 'text/html',
                                     :storage_class => :reduced_redundancy)

    log_parts = log_name.split(':')
    pkg_name = log_parts[0..1].join("/")
    date_time = log_parts[2]

    domain.items.create(log_name,
                        :matches => matches,
                        :pkg => pkg_name,
                        :date => date_time,
                        :public_url => html_log.public_url);
  end
end
