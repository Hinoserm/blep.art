# frozen_string_literal: true

require "rails_helper"

# The MakeFox flag gives IP access. Only people who already hold it can grant or remove it,
# whatever their level or other flags, and nobody can change their own.
RSpec.describe "Staff::Users MakeFox flag" do
  let(:makefox) { create(:makefox_admin_user, is_bd_staff: true) }
  let(:bd_staff) { create(:bd_staff_user) }
  let(:user) { create(:user) }

  describe "the edit form" do
    it "offers the flag to a MakeFox holder" do
      sign_in_as makefox
      get edit_staff_user_path(user)
      expect(response.body).to include("user[is_makefox]")
    end

    it "does not offer it to a staff-flag admin without it" do
      sign_in_as bd_staff
      get edit_staff_user_path(user)
      expect(response.body).not_to include("user[is_makefox]")
    end

    it "does not offer a holder their own flag" do
      sign_in_as makefox
      get edit_staff_user_path(makefox)
      expect(response.body).not_to include("user[is_makefox]")
      expect(response.body).to include("You cannot change your own MakeFox flag.")
    end
  end

  describe "PATCH /staff/users/:id" do
    it "lets a holder grant it, logged as a protected staff-flag change" do
      sign_in_as makefox
      expect do
        patch staff_user_path(user), params: { user: { is_makefox: "true" } }
      end.to change { ModAction.where(action: "user_staff_flags_change").count }.by(1)
      expect(user.reload.is_makefox?).to be true
      logged = ModAction.where(action: "user_staff_flags_change").last
      expect(logged.read_attribute(:values)).to include("user_id" => user.id, "added" => ["makefox"], "removed" => [])
    end

    it "lets a holder remove it from someone else" do
      target = create(:makefox_admin_user)
      sign_in_as makefox
      patch staff_user_path(target), params: { user: { is_makefox: "false" } }
      expect(target.reload.is_makefox?).to be false
    end

    it "ignores it from a staff-flag admin without it" do
      sign_in_as bd_staff
      patch staff_user_path(user), params: { user: { is_makefox: "true" } }
      expect(user.reload.is_makefox?).to be false
    end

    it "still applies the staff flags that admin may set in the same request" do
      sign_in_as bd_staff
      patch staff_user_path(user), params: { user: { is_makefox: "true", is_bd_auditor: "true" } }
      user.reload
      expect(user.is_makefox?).to be false
      expect(user.is_bd_auditor?).to be true
    end

    it "ignores it from a plain admin" do
      sign_in_as create(:admin_user)
      patch staff_user_path(user), params: { user: { is_makefox: "true" } }
      expect(user.reload.is_makefox?).to be false
    end

    it "does not let a holder change their own" do
      sign_in_as makefox
      patch staff_user_path(makefox), params: { user: { is_makefox: "false" } }
      expect(makefox.reload.is_makefox?).to be true
    end

    it "does not let a holder without the staff flag set the staff or auditor flags" do
      holder = create(:makefox_admin_user)
      sign_in_as holder
      patch staff_user_path(user), params: { user: { is_makefox: "true", is_bd_staff: "true", is_bd_auditor: "true" } }
      user.reload
      expect(user.is_makefox?).to be true
      expect(user.is_bd_staff?).to be false
      expect(user.is_bd_auditor?).to be false
    end
  end
end
