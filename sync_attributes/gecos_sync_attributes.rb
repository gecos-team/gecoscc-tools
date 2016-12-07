#!/usr/bin/env ruby
# Usage: gecos_sync_attributes [options]...

  require 'rubygems'
  require 'chef/cookbook/metadata'
  require 'logger'
  require 'optparse'

  $logger = Logger.new('gecos_sync_attributes.log')
  $logger.level = Logger::INFO

  class Hash
    def self.recursive
      new { |hash, key| hash[key] = recursive }
    end

    def  kdiff(b,path=[])
      a = self
      b = Hash[b.flatten] if b.is_a? Array
      diff = []

      if b.is_a? Hash
        a.each do |k,v|
          path << k
          unless b.has_key?(k)
             diff << path.clone
           else
             diff = diff.concat(a[k].kdiff(b[k],path))
          end
          path.pop
        end
      end
      diff.reject{|c| c.empty?}
    end

    def flatten_hash
      self.each_with_object({}) do |(k,v), h|
        if v.is_a? Hash
          v.flatten_hash.map do |h_k, h_v|
            h["#{k}.#{h_k}"] = h_v
          end
        else
          h[k] = v
        end
      end
    end
  end

  module MetaParser

    PATTERN = /((\.\.\*)|.\b(properties|title_es|title|description|order|required|patternProperties|type|items|minItems|uniqueItems|is_mergeable|enum|default)\b)/

    def metaparser(metafile,deep=0)
      meta = Chef::Cookbook::Metadata.new
      meta.from_file(metafile)

        attributes = meta.attributes[:json_schema][:object][:properties]["#{meta.name}"][:properties]
        metadata = Hash.recursive

        attributes.flatten_hash.keys.each do |k,v|
          i = (deep.zero?) ? k.gsub(PATTERN,'').split(".") : k.gsub(PATTERN,'').split(".").slice(0,deep) 
          str = i.inject("metadata[:#{meta.name}]") {|a,e| a += "[:#{e}\]"; a}
          eval(str)
          $logger.debug("gecos_sync_attributes.rb: Parsing metadata - #{str}")
        end
      metadata
    end

    def transform_hash(original, options={}, &block)
      original.inject({}){|result, (key,value)|
      value = if (options[:deep] && Hash === value) 
        transform_hash(value, options, &block)
      else 
        if Array === value
          value.map{|v| transform_hash(v, options, &block)}
        else
           value
         end
      end
      block.call(result,key,value)
      result
    }
    end

    # Convert keys to strings
    def stringify_keys(hash)
      transform_hash(hash) {|hash, key, value|
        hash[key.to_s] = value
      }
    end
    
    # Convert keys to strings, recursively
    def deep_stringify_keys(hash)
      transform_hash(hash, :deep => true) {|hash, key, value|
        hash[key.to_s] = value
    }
    end
end

begin
    options = {}
    OptionParser.new do |opts|
      opts.banner = "Usage: gecos_sync_attributes [options]"
      opts.on("-o", "--cookbook_path DIRECTORY", "Mandatory cookbook path") do |path|
        options[:cookbook_path] = path
      end
      opts.on("-h", "--help", "Prints this help") do
        puts opts
        exit
      end
    end.parse!
    
    raise OptionParser::MissingArgument.new("-o (--cookbook_path) required argument") if options[:cookbook_path].nil?
    
    include MetaParser

    cookbook_path = options[:cookbook_path]
    metafile = "#{cookbook_path}/metadata.rb"
        
    abort("Non-existent cookbook path or metadata.rb") if not (File.directory?(cookbook_path) and File.exists?(metafile))

    metadata = metaparser(metafile,3)

    default = Hash.recursive
    eval File.open("#{cookbook_path}/attributes/default.rb").read

    kdiffs = metadata.kdiff(default).map{|c| c.join(".")}
    puts kdiffs
    $logger.info("gecos_sync_attributes.rb: attributes - #{kdiffs.inspect}")

rescue => err
    puts err    
    $logger.fatal("Caught exception; exiting #{err}")
end
