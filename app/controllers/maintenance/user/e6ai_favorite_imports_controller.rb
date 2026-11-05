# frozen_string_literal: true

module Maintenance
  module User
    class E6aiFavoriteImportsController < ApplicationController
      INVALID_ID_MESSAGE = "Enter your e6ai.net user ID, or paste your e6ai.net profile link."

      before_action :member_only
      before_action :ensure_favorites_enabled, only: :create
      before_action :load_import

      def show
        respond_to do |format|
          format.html
          format.json { render json: @import&.progress_json || { status: "none" } }
        end
      end

      def create
        @submitted_user_id = submitted_user_id
        e6ai_user_id = E6aiFavoriteImport.parse_user_id(@submitted_user_id)
        unless E6aiFavoriteImport.new(user: CurrentUser.user, e6ai_user_id: e6ai_user_id).valid?
          flash.now[:notice] = INVALID_ID_MESSAGE
          return render(:show, status: :unprocessable_content)
        end

        if start_import(e6ai_user_id)
          enqueue
        elsif @import&.done?
          flash[:notice] = "You have already imported your e6ai.net favorites."
        else
          flash[:notice] = "Your import is already running."
        end
        redirect_to maintenance_user_e6ai_favorite_import_path
      end

      private

      def load_import
        @import = E6aiFavoriteImport.find_by(user_id: CurrentUser.id)
      end

      def submitted_user_id
        form = params[:e6ai_favorite_import]
        form.is_a?(ActionController::Parameters) ? form[:e6ai_user_id].to_s : ""
      end

      # Creates the import, or restarts a failed or stalled one. The restart is a single
      # conditional update, so two submissions at once cannot both start a job.
      # Returns false when an import exists that may not be restarted.
      def start_import(e6ai_user_id)
        if @import.nil?
          @import = E6aiFavoriteImport.create!(user: CurrentUser.user, e6ai_user_id: e6ai_user_id)
          return true
        end
        restarted = E6aiFavoriteImport.restartable.where(id: @import.id, attempt: @import.attempt).update_all(
          E6aiFavoriteImport::RESET_ATTRIBUTES.merge(e6ai_user_id: e6ai_user_id, attempt: @import.attempt + 1, updated_at: Time.current),
        )
        @import.reload
        restarted == 1
      rescue ActiveRecord::RecordNotUnique
        @import = E6aiFavoriteImport.find_by(user_id: CurrentUser.id)
        false
      end

      def enqueue
        E6aiFavoriteImportJob.perform_async(@import.id, @import.attempt)
      rescue StandardError => e
        Rails.logger.error("E6aiFavoriteImportsController: could not enqueue import #{@import.id}: #{e.class}: #{e.message}")
        E6aiFavoriteImport.where(id: @import.id, attempt: @import.attempt)
                          .update_all(status: "failed", error: "The import could not be started. Please try again.", updated_at: Time.current)
      end

      def ensure_favorites_enabled
        return unless Security::Lockdown.favorites_disabled? && !CurrentUser.is_staff?
        flash[:notice] = "Favorites are disabled right now. Please try again later."
        redirect_to maintenance_user_e6ai_favorite_import_path
      end
    end
  end
end
