defmodule NsparkWeb.AuthOverrides do
  use AshAuthentication.Phoenix.Overrides

  alias AshAuthentication.Phoenix.{
    Components,
    ConfirmLive,
    MagicSignInLive,
    ResetLive,
    SignInLive
  }

  # ── Page roots ──────────────────────────────────────────────────────────────

  override SignInLive do
    set :root_class, "auth-root"
  end

  override ResetLive do
    set :root_class, "auth-root"
  end

  override ConfirmLive do
    set :root_class, "auth-root"
  end

  override MagicSignInLive do
    set :root_class, "auth-root"
  end

  # ── Brand banner (replaces the Ash logo) ────────────────────────────────────

  override Components.Banner do
    set :root_class, "auth-brand"
    set :image_url, nil
    set :dark_image_url, nil
    set :image_class, nil
    set :dark_image_class, nil
    set :text, "Newtonian Spark"
    set :text_class, "auth-brand-text"
    set :href_class, "auth-brand-link"
    set :href_url, "/"
  end

  # ── Sign-in container ────────────────────────────────────────────────────────

  override Components.SignIn do
    set :root_class, "auth-box"
    set :strategy_class, ""
    set :authentication_error_container_class, "auth-auth-error"
    set :authentication_error_text_class, ""
    set :strategy_display_order, :forms_first
  end

  override Components.Confirm do
    set :root_class, "auth-box"
    set :strategy_class, ""
  end

  override Components.Reset do
    set :root_class, "auth-box"
    set :strategy_class, ""
  end

  # ── Password component (sign-in / register / reset toggler) ─────────────────

  override Components.Password do
    set :root_class, "auth-section"
    set :interstitial_class, "auth-links"
    set :toggler_class, "auth-link"
    set :sign_in_toggle_text, "Already have an account?"
    set :register_toggle_text, "Need an account?"
    set :reset_toggle_text, "Forgot your password?"
    set :show_first, :sign_in
    set :hide_class, "hidden"
  end

  override Components.Password.SignInForm do
    set :root_class, nil
    set :label_class, "auth-form-head"
    set :form_class, nil
    set :slot_class, nil
    set :button_text, "▸ Sign In"
    set :disable_button_text, "Signing in…"
  end

  override Components.Password.RegisterForm do
    set :root_class, nil
    set :label_class, "auth-form-head"
    set :form_class, nil
    set :slot_class, nil
    set :button_text, "▸ Register"
    set :disable_button_text, "Registering…"
  end

  override Components.Password.ResetForm do
    set :root_class, nil
    set :label_class, "auth-form-head"
    set :form_class, nil
    set :slot_class, nil
    set :button_text, "Send Reset Link"
    set :disable_button_text, "Sending…"

    set :reset_flash_text,
        "If this email exists, you will receive password reset instructions shortly."
  end

  override Components.Password.Input do
    set :field_class, "auth-field"
    set :label_class, "auth-label"
    set :input_class, "auth-input"
    set :input_class_with_error, "auth-input auth-input--error"
    set :submit_class, "auth-submit"
    set :error_ul, "auth-errors"
    set :error_li, "auth-error-item"
    set :identity_input_label, "Email"
    set :password_input_label, "Password"
    set :password_confirmation_input_label, "Confirm Password"
    set :input_debounce, 350
  end

  # ── Magic link ───────────────────────────────────────────────────────────────

  override Components.MagicLink do
    set :root_class, "auth-section"
    set :label_class, "auth-form-head"
    set :form_class, nil
    set :request_flash_text, "Check your inbox for a sign-in link."
  end

  override Components.MagicLink.Input do
    set :submit_class, "auth-submit"
    set :input_debounce, 350
    set :submit_label, "▸ Send Magic Link"
    set :disable_button_text, "Sending…"
  end

  # ── Divider ──────────────────────────────────────────────────────────────────

  override Components.HorizontalRule do
    set :root_class, "auth-divider"
    set :hr_outer_class, "absolute inset-0 flex items-center"
    set :hr_inner_class, "w-full auth-divider-hr"
    set :text_outer_class, "relative flex justify-center"
    set :text_inner_class, "auth-divider-label"
    set :text, "or"
  end

  # ── Flash messages ───────────────────────────────────────────────────────────

  override Components.Flash do
    set :message_class_info, "auth-flash auth-flash--info"
    set :message_class_error, "auth-flash auth-flash--error"
  end
end
