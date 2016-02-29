module Bosh
  module Director
    module DeploymentPlan
      class TransientDeployment
        def initialize(name, manifest, release_versions)
          @name = name
          @manifest = manifest
          @release_versions = release_versions
          @vms = []
        end
        attr_accessor :name, :manifest, :release_versions, :vms
      end

      class PlannerFactory
        def self.create(logger)
          deployment_manifest_migrator = Bosh::Director::DeploymentPlan::ManifestMigrator.new
          manifest_validator = Bosh::Director::DeploymentPlan::ManifestValidator.new
          deployment_repo = Bosh::Director::DeploymentPlan::DeploymentRepo.new

          new(
            deployment_manifest_migrator,
            manifest_validator,
            deployment_repo,
            logger
          )
        end

        def initialize(deployment_manifest_migrator, manifest_validator, deployment_repo, logger)
          @deployment_manifest_migrator = deployment_manifest_migrator
          @manifest_validator = manifest_validator
          @deployment_repo = deployment_repo
          @logger = logger
        end

        def create_from_model(deployment_model, options={})
          manifest = Manifest.load_from_text(deployment_model.manifest, deployment_model.cloud_config, deployment_model.runtime_config)
          create_from_manifest(manifest, deployment_model.cloud_config, deployment_model.runtime_config, options)
        end

        def create_from_manifest(manifest, cloud_config, runtime_config, options)
          parse_from_manifest(manifest, cloud_config, runtime_config, options)
        end

        private

        def parse_from_manifest(manifest, cloud_config, runtime_config, options)
          manifest.resolve_aliases
          @manifest_validator.validate(manifest.manifest_hash, manifest.cloud_config_hash)
          deployment_manifest, cloud_manifest = @deployment_manifest_migrator.migrate(manifest.manifest_hash, manifest.cloud_config_hash)
          @logger.debug("Migrated deployment manifest:\n#{deployment_manifest}")
          @logger.debug("Migrated cloud config manifest:\n#{cloud_manifest}")
          name = deployment_manifest['name']

          deployment_model = @deployment_repo.find_or_create_by_name(name, options)

          attrs = {
            name: name,
            properties: deployment_manifest.fetch('properties', {}),
          }

          plan_options = {
            'recreate' => !!options['recreate'],
            'skip_drain' => options['skip_drain'],
            'job_states' => options['job_states'] || {},
          }

          @logger.info('Creating deployment plan')
          @logger.info("Deployment plan options: #{plan_options}")

          deployment = Planner.new(attrs, deployment_manifest, cloud_config, runtime_config, deployment_model, plan_options)
          global_network_resolver = GlobalNetworkResolver.new(deployment)

          ip_provider_factory = IpProviderFactory.new(deployment.using_global_networking?, @logger)
          deployment.cloud_planner = CloudManifestParser.new(@logger).parse(cloud_manifest, global_network_resolver, ip_provider_factory)
          DeploymentSpecParser.new(deployment, Config.event_log, @logger).parse(deployment_manifest, plan_options)

          if runtime_config
            RuntimeManifestParser.new(@logger, deployment).parse(runtime_config.manifest)
          end

          process_links(deployment)

          DeploymentValidator.new.validate(deployment)
          deployment
        end

        def process_links(deployment)
          errors = []

          deployment.jobs.each do |current_job|
            current_job.templates.each do |template|
              if template.link_infos.has_key?(current_job.name) && template.link_infos[current_job.name].has_key?('consumes')
                template.link_infos[current_job.name]['consumes'].each do |name, source|
                  link_path = LinkPath.new(deployment, current_job.name, template.name)

                  begin
                    link_path.parse(source)
                  rescue Exception => e
                    errors.push e
                  end

                  if !link_path.skip
                    current_job.add_link_path(template.name, name, link_path)
                  end
                end
              end
            end
          end

          if errors.length > 0
            message = 'Unable to process links for deployment. Errors are:'

            errors.each do |e|
              message = "#{message}\n   - \"#{e.message.gsub(/\n/, "\n  ")}\""
            end

            raise message
          end
        end
      end
    end
  end
end
