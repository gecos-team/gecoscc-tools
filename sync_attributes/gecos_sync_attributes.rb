#!/usr/bin/env ruby
# Usage: gecos_sync_attributes [options]...

  require 'rubygems'
  require 'chef/cookbook/metadata'
  require 'chef/util/file_edit'
  require 'logger'
  require 'optparse'
  require 'set'

  $logger = Logger.new('gecos_sync_attributes.log')
  $logger.level = Logger::INFO
  $logger.progname = 'gecos_sync_attributes.rb'
  $logger.formatter = proc do |severity, datetime, progname, msg|
    date_format = datetime.strftime("%Y-%m-%d %H:%M:%S")
    if severity == "INFO" or severity == "WARN"
        "[#{date_format}] #{severity}  (#{progname}): #{msg}\n"
    else        
        "[#{date_format}] #{severity} (#{progname}): #{msg}\n"
    end
  end


  class Hash
    def self.recursive
      new { |hash, key| hash[key] = recursive }
    end

    def transform_leaves_to_hash
   	leaves = []

    	each do |key,value|
    	  value.is_a?(Hash) ? value.transform_leaves_to_hash.each{|l| leaves << l } : self[key] = {}
    	end
    	self
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
end

begin
    include MetaParser

    # PARAMS
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
    
    cookbook_path = options[:cookbook_path]
    metafile = "#{cookbook_path}/metadata.rb"
        
    abort("Non-existent cookbook path or metadata.rb") if not (File.directory?(cookbook_path) and File.exists?(metafile))

    ###############
    #	RECIPES	  #
    ###############
    puts "\nDESYNCHRONIZED METADATA SECTIONS"
    $logger.info("RECIPES\n")

    # Read complete file into variable
    data = File.read(metafile)

    # Excludes
    excludes_re = "(#|updated_js|support_os_js|complete_js)"

    # Declarative section of recipes
    declarative_section = data.scan(/(^.*_js)\s+=\s+{/).flatten
    declarative_section.reject! { |p| p =~ /#{excludes_re}/ }
    declarative_section = declarative_section.to_set

    # support_os section of recipes
    support_os_re = "(.*_js)".concat(Regexp.escape("[:properties][:support_os][:default]"))
    os_section = data.scan(/#{support_os_re}/).flatten
    os_section.reject! { |p| p =~ /#{excludes_re}/ }
    os_section = os_section.to_set
 
    # complete_js section of recipes
    complete_section = Set.new
    data.scan(/(.*_res:\s*(.*_js))/) do |line,recp|
	next if line =~ /#{excludes_re}/
  	complete_section << recp
    end

    # All recipes (union)
    all = declarative_section | os_section | complete_section

    desync_recipes_declare = (all - declarative_section).to_a.sort
    desync_recipes_os = (all - os_section).to_a.sort
    desync_recipes_complete = (all - complete_section).to_a.sort

    # STDOUT & LOG
    puts "\n\tMissing recipes in declarative section"
    puts  desync_recipes_declare.any? ? "\t\t#{desync_recipes_declare}" : "\t\tAll OK."
    $logger.info("Missing attributes file section declarative => #{desync_recipes_declare}\n")
    puts "\n\tMissing recipes in defaults os section"
    puts desync_recipes_os.any? ? "\t\t#{desync_recipes_os}" : "\t\tAll OK."
    $logger.info("Missing attributes file section support_os => #{desync_recipes_os}")
    puts "\n\tMissing recipes in complete_js section"
    puts desync_recipes_complete.any? ? "\t\t#{desync_recipes_complete}" : "\t\tAll OK."
    $logger.info("Missing attributes file section complete_js => #{desync_recipes_complete}\n")
    
    ##################
    #	ATTRIBUTES   #
    ##################
    
    # Recipe not declared. This metadata can not be uploaded to chef-server because of an error: 
    # Exception: NameError: undefined local variable or method `system_proxy_js' for #<Chef::Cookbook::Metadata:0x007f8845fc3558>
    if desync_recipes_declare.any?
	fe = Chef::Util::FileEdit.new(metafile) if desync_recipes_declare.any?
	desync_recipes_declare.each do |i|
        	fe.search_file_replace_line(/#{i}/,"# Recipe not declared #{i}")
    	end
    	fe.write_file
    end

    puts "\nDIFFERENCES BETWEEN METADATA.RB AND ATTRIBUTES/DEFAULT.RB"
    puts "\n\tRecipes used for comparison (complete_js):\n"
    comparison_recipes = ( complete_section - desync_recipes_declare ).to_a.sort
    if comparison_recipes.any?
    	comparison_recipes.map {|s| puts "\t\t#{s}"}
    else
	 puts "\t\tAll OK."
    end
    $logger.info("Recipes used for comparison => #{(complete_section - desync_recipes_declare).to_a.sort}")
    puts "\n\tRecipes missing  in complete_js, not used for comparison:\n"
    not_comparison_recipes = ( desync_recipes_complete | desync_recipes_declare )
    if not_comparison_recipes.any? 
	not_comparison_recipes.map {|s| puts "\t\t#{s}"}
    else
	 puts "\t\tAll OK."
    end
    $logger.info("Recipes missing in complete_js or not present in declarative section, not used for comparison=> #{desync_recipes_complete|desync_recipes_declare}")

    puts "\n\tThe following attributes are found in metadata.rb but not in attributes/default.rb:\n"
    $logger.info("DIFFERENCES BETWEEN METADATA.RB AND ATTRIBUTES/DEFAULT.RB")
    $logger.info("The following attributes are found in metadata.rb but not in attributes/default.rb\n")

    metadata = metaparser(metafile,3)

    default = Hash.recursive
    eval File.open("#{cookbook_path}/attributes/default.rb").read

    kdiffs = metadata.kdiff(default).map{|c| c.join(".")}
    default = default.transform_leaves_to_hash
    # STDOUT & LOG
    if kdiffs.any?
	kdiffs.map {|s| puts "\t\t#{s}"}
    else
	 puts "\t\tAll OK."
    end
    $logger.info("attributes - #{kdiffs.inspect}")

    puts "\n\tThe following attributes are found in attributes/default.rb but not in metadata.rb:\n"
    metadata = metaparser(metafile)
    rdiffs = default.kdiff(metadata).map{|c| c.join(".")}
    if rdiffs.any? 
	rdiffs.map {|s| puts (s.count('.') == 2) ? "\t\t#{s} (ALL recipe attributes)" : "\t\t#{s}"} 
    else
	puts "\t\tAll OK."
    end
    $logger.info("The following attributes are found in attributes/default.rb but not in metadata.rb\n")
    $logger.info("attributes - #{rdiffs.inspect}")

rescue => err
    puts err    
    $logger.fatal("Caught exception; exiting #{err}")
end
