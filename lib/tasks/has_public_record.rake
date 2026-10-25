# frozen_string_literal: true

namespace :has_public_record do
  # Models register their prefix when their class loads, so load them all first.
  task prepare: :environment do
    Rails.application.eager_load!
  end

  def hpr_models
    only = ENV["MODEL"].presence
    models = HasPublicRecord::Maintenance.models(only: only)
    abort "No model#{" named #{only}" if only} declares has_public_record." if models.empty?
    models
  end

  desc "Give every row without a public id one (MODEL=User to limit)"
  task backfill: :prepare do
    hpr_models.each do |model|
      problem = HasPublicRecord::Maintenance.report(model).problem
      next puts("#{model.name}: skipped, #{problem}") if problem

      puts "#{model.name}: #{model.backfill_public_ids!} rows given an id"
    end
  end

  desc "Missing ids, wrong prefixes, duplicates and capacity (MODEL=User to limit). Exits 1 when anything is off"
  task report: :prepare do
    reports = HasPublicRecord::Maintenance.reports(only: ENV["MODEL"].presence)
    abort "No model declares has_public_record." if reports.empty?

    reports.each do |r|
      label = "#{r.model.name} (#{r.table}.#{r.column}, prefix #{r.model.public_id_prefix})"
      if r.problem
        puts "#{label}: #{r.problem}"
      elsif r.ok?
        puts "#{label}: #{r.total} rows, ok; #{HasPublicRecord::Maintenance.capacity(r.model)}"
      else
        puts "#{label}: #{r.total} rows, #{r.missing} missing, #{r.wrong_prefix} wrong prefix" \
             "#{" (e.g. #{r.wrong_samples.join(', ')})" if r.wrong_samples.any?}, #{r.duplicates} duplicated; " \
             "#{HasPublicRecord::Maintenance.capacity(r.model)}"
      end
    end
    exit 1 unless reports.all?(&:ok?)
  end

  desc "Rename stored ids from an old prefix to the model's declared one: MODEL=User FROM=old [APPLY=1]"
  task rename: :prepare do
    from = ENV["FROM"].presence or abort "Give the old prefix: FROM=old"
    ENV["MODEL"].presence or abort "Give the model: MODEL=User"
    model = hpr_models.first
    apply = ENV["APPLY"].present?

    count = HasPublicRecord::Maintenance.rename_prefix(model, from: from, apply: apply)
    if apply
      puts "#{model.name}: #{count} ids renamed #{from}_ -> #{model.public_id_prefix}_"
    else
      puts "#{model.name}: #{count} ids would be renamed #{from}_ -> #{model.public_id_prefix}_ (dry run; add APPLY=1)"
    end
  end
end
