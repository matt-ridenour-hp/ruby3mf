require_relative 'mesh_analyzer'

class Model3mf

  VALID_UNITS = ['micron', 'millimeter', 'centimeter', 'meter', 'inch', 'foot'].freeze
  VALID_EXTENSIONS = {
    'http://schemas.microsoft.com/3dmanufacturing/slice/2015/07' => {},
    'http://schemas.microsoft.com/3dmanufacturing/material/2015/02' => {},
    'http://schemas.microsoft.com/3dmanufacturing/production/2015/06' => {},
  }.freeze


  def self.xsd_validation(zip_entry)
    xsd = Nokogiri::XML::Schema(File.read('./lib/ruby3mf/3MFcoreSpec_1.1.xsd'))
    doc = Nokogiri::XML(zip_entry.get_input_stream)
    xsd.validate(doc)
  end

  def self.parse(document, zip_entry)
    model_doc = nil
    relationships = nil
    relationship_resources = []

    Log3mf.context "parsing model" do |l|
      begin
        model_doc = XmlVal.validate_parse(zip_entry)
      rescue Nokogiri::XML::SyntaxError => e
        l.fatal_error "Model file invalid XML. Exception #{e}"
      end

      Log3mf.context "validating core schema" do |l|

        core_schema_errors = xsd_validation(zip_entry)

        l.error :invalid_xml_core if core_schema_errors.size > 0

      end

      l.context "verifying requiredextensions" do |l|
        required_extensions = model_doc.css("//model")[0]["requiredextensions"]
        if required_extensions
          required_extensions.split(" ").each do |ns|
            namespace_uri = model_doc.namespaces["xmlns:#{ns}"]
            if namespace_uri
              if VALID_EXTENSIONS.has_key? namespace_uri
                l.info "Found a valid required extension: #{namespace_uri}"
              else
                l.error :unknown_required_extension, ext: namespace_uri
              end
            else
              l.error :missing_extension_namespace_uri, ns: ns
            end
          end
        end
      end

      l.context "verifying 3D payload required resources" do |l|
        # results = model_doc.css("model resources m:texture2d")
        required_resources = model_doc.css("//model//resources//*[path]").collect { |n| n["path"] }
        required_resources += model_doc.css("//model//resources//object[thumbnail]").collect { |n| n["thumbnail"] }

        # for each, ensure that they exist in m.relationships
        relationship_resources = []
        rel_file = "#{Pathname(zip_entry.name).dirname.to_s}/_rels/#{File.basename(zip_entry.name)}.rels"
        relationships = document.relationships[rel_file]
        unless (relationships.nil?)
          relationship_resources = relationships.map { |relationship| relationship[:target] }
        end

        missing_resources = (required_resources - relationship_resources)
        if missing_resources.empty?
          l.info "All model required resources are defined in .rels relationship files."
        else
          missing_resources.each { |mr|
            l.error :model_resource_not_in_rels, mr: mr
          }
        end

        l.context "verifying 3D resource types" do |l|
          model_types = model_doc.css("//model//resources//*[path]").collect { |t| t["contenttype"] }

          #for each, ensure they exist in ContentTypes
          all_types = document.types.map { |t, v| v }

          bad_types = (model_types - all_types)
          if bad_types.empty?
            l.info "All model resource contenttypes are valid"
          else
            bad_types.each { |bt|
              l.error :resource_contentype_invalid, bt: bt
            }
          end
        end

      end

      l.context "verifying resources" do |l|
        resources = find_child(model_doc.root, "resources")
        if resources
          ids = resources.children.map { |child| child.attributes["id"].to_s() if child.attributes["id"] }
          l.error :resource_id_collision if ids.uniq.size != ids.size
        end
      end

      l.context "verifying build items" do |l|
        build = find_child(model_doc.root, "build")
        if build
          items = build.children.map { |child| child.attributes["objectid"].to_s() if child.name == "item" }

          resources = find_child(model_doc.root, "resources")
          resources.children.each do |resource|
            if resource.name == "object"
              object_id = resource.attributes["id"].to_s()
              l.error :build_with_other_item if resource.attributes["type"].to_s() == "other" and items.include?(object_id)
            end
          end
        end
      end

      l.context "checking metadata" do |l|

        metadata = model_doc.root.css("metadata")

        metadata_names = metadata.map { |met| met['name'] }
        l.error :metadata_elements_with_same_name unless metadata_names.uniq!.nil?

        # metadata values allowed under default namespace (xmlns):
        metadata_values = ['Title', 'Designer', 'Description', 'Copyright', 'LicenseTerms', 'Rating', 'CreationDate', 'ModificationDate']

        known_namespaces = ["http://schemas.microsoft.com/3dmanufacturing/core/2015/02", "http://schemas.microsoft.com/3dmanufacturing/material/2015/02"]
        only_known_namespaces = model_doc.root.namespace_definitions.all? { |ns| known_namespaces.include?(ns.href) }
        unless model_doc.root.namespace.href.nil? || !only_known_namespaces
          l.error :invalid_metadata_under_defaultns unless (metadata_names - metadata_values).empty?
        end
      end

      MeshAnalyzer.validate(model_doc)
    end
    model_doc
  end
end
