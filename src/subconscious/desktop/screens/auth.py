"""
Account / authentication screen for the desktop UI.

Renders either the signed-in profile card or the full set of unauthenticated
flows (login, email signup with verification code + password, password reset,
and GitHub sign-in). All server communication is delegated to the async
callbacks supplied by the skeleton, which wrap ``engine.auth``.

Each callback returns a small result dict so this component can stay UI-only:
  {"ok": bool, "error": str | None, "token": str | None}
"""
import asyncio
import flet as ft

from ...shared.forms import FormField, PasswordField
from ...shared.buttons import TextButton
from ...shared.identicon import identicon


# Flow modes for the unauthenticated view
_LOGIN = "login"
_SIGNUP_EMAIL = "signup_email"
_SIGNUP_VERIFY = "signup_verify"
_SIGNUP_PASSWORD = "signup_password"
_RESET_REQUEST = "reset_request"
_RESET_CONFIRM = "reset_confirm"


@ft.component
def AccountWindow(
  user=None,
  is_authenticated: bool = False,
  on_login_email=None,
  on_register_email=None,
  on_verify_email=None,
  on_complete_signup=None,
  on_request_reset=None,
  on_confirm_reset=None,
  on_github_login=None,
  on_logout=None,
) -> ft.Control:
  """Render the account view."""

  mode, set_mode = ft.use_state(_LOGIN)
  email, set_email = ft.use_state("")
  password, set_password = ft.use_state("")
  confirm, set_confirm = ft.use_state("")
  code, set_code = ft.use_state("")
  display_name, set_display_name = ft.use_state("")
  verify_token, set_verify_token = ft.use_state("")
  error, set_error = ft.use_state("")
  info, set_info = ft.use_state("")
  busy, set_busy = ft.use_state(False)

  def reset_feedback():
    set_error("")
    set_info("")

  def go(target_mode):
    reset_feedback()
    set_mode(target_mode)

  # ── Signed-in profile card ────────────────────────────────────────────────
  if is_authenticated and user:
    seed = user.get("id") or user.get("email") or "subconscious"
    name = user.get("display_name") or user.get("email") or "Signed in"
    providers = user.get("connected_providers") or []

    async def handle_logout(e):
      set_busy(True)
      if on_logout:
        await on_logout()
      set_busy(False)

    provider_chips = ft.Row(
      [
        ft.Container(
          content=ft.Text(p.capitalize(), size=12),
          padding=ft.padding.symmetric(4, 10),
          border_radius=3,
          bgcolor=ft.Colors.SECONDARY_CONTAINER,
        )
        for p in providers
      ],
      wrap=True,
      spacing=6,
    ) if providers else ft.Text("Email & password", size=12, color=ft.Colors.GREY)

    return ft.Container(
      content=ft.Column(
        [
          ft.Image(src=identicon(seed, size=96), width=96, height=96, border_radius=6),
          ft.Text(name, size=22, weight=ft.FontWeight.W_500, color=ft.Colors.PRIMARY),
          ft.Text(user.get("email", ""), size=14, color=ft.Colors.GREY),
          ft.Container(height=8),
          ft.Text("Connected", size=12, color=ft.Colors.GREY),
          provider_chips,
          ft.Container(height=16),
          TextButton(on_click=handle_logout, text="Sign out", icon=ft.Icons.LOGOUT, disabled=busy),
        ],
        spacing=8,
        expand=True,
        alignment=ft.MainAxisAlignment.CENTER,
        horizontal_alignment=ft.CrossAxisAlignment.CENTER,
      ),
      expand=True,
      padding=ft.padding.all(24),
    )

  # ── Shared feedback + busy helpers for the form flows ─────────────────────
  async def run(callback, *args):
    """Invoke an async callback, manage busy state, and surface errors.

    Returns the result dict (or None when no callback is wired).
    """
    if not callback:
      return None
    reset_feedback()
    set_busy(True)
    try:
      result = await callback(*args)
    except Exception as exc:  # defensive: callbacks already trap AuthError
      set_busy(False)
      set_error(str(exc))
      return {"ok": False, "error": str(exc)}
    set_busy(False)
    if result and not result.get("ok"):
      set_error(result.get("error") or "Something went wrong.")
    return result

  # ── Action handlers ───────────────────────────────────────────────────────
  async def do_login(e):
    await run(on_login_email, email, password)

  async def do_github(e):
    await run(on_github_login)

  async def do_register(e):
    result = await run(on_register_email, email)
    if result and result.get("ok"):
      set_info("We sent a verification code to your email.")
      set_mode(_SIGNUP_VERIFY)

  async def do_verify(e):
    result = await run(on_verify_email, email, code)
    if result and result.get("ok"):
      set_verify_token(result.get("token", ""))
      set_info("Email verified. Choose a password.")
      set_mode(_SIGNUP_PASSWORD)

  async def do_complete(e):
    if password != confirm:
      set_error("Passwords don't match.")
      return
    result = await run(on_complete_signup, verify_token, password, display_name)
    # On success the parent flips is_authenticated and this view re-renders.
    if result and result.get("ok"):
      set_info("")

  async def do_request_reset(e):
    result = await run(on_request_reset, email)
    if result and result.get("ok"):
      set_info("If that email exists, a reset code is on its way.")
      set_mode(_RESET_CONFIRM)

  async def do_confirm_reset(e):
    if password != confirm:
      set_error("Passwords don't match.")
      return
    await run(on_confirm_reset, email, code, password)

  # ── Reusable bits ─────────────────────────────────────────────────────────
  def feedback_controls():
    items = []
    if error:
      items.append(
        ft.Row(
          [
            ft.Icon(ft.Icons.ERROR_OUTLINE, size=16, color=ft.Colors.ERROR),
            ft.Text(error, size=13, color=ft.Colors.ERROR, expand=True),
          ],
          spacing=6,
        )
      )
    if info:
      items.append(
        ft.Row(
          [
            ft.Icon(ft.Icons.INFO_OUTLINE, size=16, color=ft.Colors.GREY),
            ft.Text(info, size=13, color=ft.Colors.GREY, expand=True),
          ],
          spacing=6,
        )
      )
    return items

  def header(title, subtitle=None):
    rows = [ft.Text(title, size=24, weight=ft.FontWeight.W_500, color=ft.Colors.PRIMARY)]
    if subtitle:
      rows.append(ft.Text(subtitle, size=14, color=ft.Colors.GREY))
    return ft.Column(rows, spacing=2)

  def link(text, target_mode, on_click=None):
    return ft.TextButton(
      content=ft.Text(text, size=13, color=ft.Colors.PRIMARY),
      on_click=on_click or (lambda e: go(target_mode)),
      style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
    )

  # ── Build the active form ─────────────────────────────────────────────────
  if mode == _LOGIN:
    form = ft.Column(
      [
        header("Welcome back", "Sign in to sync your account."),
        ft.Container(height=8),
        TextButton(
          on_click=do_github,
          text="Continue with GitHub",
          icon=ft.Icons.CODE,
          disabled=busy,
        ),
        ft.Divider(height=24, color=ft.Colors.OUTLINE_VARIANT),
        FormField("Email", email, lambda e: set_email(e.control.value), "you@example.com"),
        PasswordField("Password", password, lambda e: set_password(e.control.value), "Your password"),
        *feedback_controls(),
        TextButton(on_click=do_login, text="Sign in", disabled=busy),
        ft.Row(
          [
            link("Create an account", _SIGNUP_EMAIL),
            ft.Container(expand=True),
            link("Forgot password?", _RESET_REQUEST),
          ],
        ),
      ],
      spacing=12,
    )

  elif mode == _SIGNUP_EMAIL:
    form = ft.Column(
      [
        header("Create your account", "We'll email you a verification code."),
        ft.Container(height=8),
        TextButton(
          on_click=do_github,
          text="Sign up with GitHub",
          icon=ft.Icons.CODE,
          disabled=busy,
        ),
        ft.Divider(height=24, color=ft.Colors.OUTLINE_VARIANT),
        FormField("Email", email, lambda e: set_email(e.control.value), "you@example.com"),
        *feedback_controls(),
        TextButton(on_click=do_register, text="Send code", disabled=busy),
        ft.Row([ft.Text("Already have an account?", size=13, color=ft.Colors.GREY), link("Sign in", _LOGIN)]),
      ],
      spacing=12,
    )

  elif mode == _SIGNUP_VERIFY:
    form = ft.Column(
      [
        header("Check your email", f"Enter the code we sent to {email}."),
        ft.Container(height=8),
        FormField("Verification code", code, lambda e: set_code(e.control.value), "6-digit code"),
        *feedback_controls(),
        TextButton(on_click=do_verify, text="Verify", disabled=busy),
        ft.Row(
          [
            link("Use a different email", _SIGNUP_EMAIL),
            ft.Container(expand=True),
            link("Resend code", None, on_click=do_register),
          ],
        ),
      ],
      spacing=12,
    )

  elif mode == _SIGNUP_PASSWORD:
    form = ft.Column(
      [
        header("Set a password", "Pick something at least 8 characters long."),
        ft.Container(height=8),
        FormField("Display name (optional)", display_name, lambda e: set_display_name(e.control.value), "How should we call you?"),
        PasswordField("Password", password, lambda e: set_password(e.control.value), "New password"),
        PasswordField("Confirm password", confirm, lambda e: set_confirm(e.control.value), "Re-enter password"),
        *feedback_controls(),
        TextButton(on_click=do_complete, text="Create account", disabled=busy),
      ],
      spacing=12,
    )

  elif mode == _RESET_REQUEST:
    form = ft.Column(
      [
        header("Reset your password", "We'll email you a reset code."),
        ft.Container(height=8),
        FormField("Email", email, lambda e: set_email(e.control.value), "you@example.com"),
        *feedback_controls(),
        TextButton(on_click=do_request_reset, text="Send reset code", disabled=busy),
        ft.Row([link("Back to sign in", _LOGIN)]),
      ],
      spacing=12,
    )

  else:  # _RESET_CONFIRM
    form = ft.Column(
      [
        header("Choose a new password", f"Enter the code sent to {email}."),
        ft.Container(height=8),
        FormField("Reset code", code, lambda e: set_code(e.control.value), "6-digit code"),
        PasswordField("New password", password, lambda e: set_password(e.control.value), "New password"),
        PasswordField("Confirm password", confirm, lambda e: set_confirm(e.control.value), "Re-enter password"),
        *feedback_controls(),
        TextButton(on_click=do_confirm_reset, text="Reset password", disabled=busy),
        ft.Row([link("Back to sign in", _LOGIN)]),
      ],
      spacing=12,
    )

  return ft.Container(
    content=ft.Column(
      [
        ft.Container(
          content=ft.Column(
            [
              ft.Image(src="/logo.svg", width=56, height=56, color=ft.Colors.PRIMARY),
              form,
            ],
            spacing=16,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
          ),
          width=380,
          padding=ft.padding.all(8),
        ),
      ],
      expand=True,
      alignment=ft.MainAxisAlignment.CENTER,
      horizontal_alignment=ft.CrossAxisAlignment.CENTER,
      scroll=ft.ScrollMode.ADAPTIVE,
    ),
    expand=True,
    padding=ft.padding.all(24),
  )
