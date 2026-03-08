import asyncio
import flet as ft


@ft.component
def ChatWindow(thread=None, messages=None, on_send_message=None) -> ft.Control:
  """ Handles the main chat window, including message display and input form """
  
  # Dummy state and logic to resolve rendering errors from older version
  def llm_configured(): return True
  def focus_message_form(e): pass
  
  message_form = ft.TextField(hint_text="Type a message...", expand=True, border=ft.InputBorder.NONE)
  tools = ft.Row([ft.Icon(ft.Icons.ATTACH_FILE), ft.Icon(ft.Icons.IMAGE)])
  message_controls = ft.IconButton(icon=ft.Icons.SEND, on_click=lambda _: on_send_message("dummy") if on_send_message else None)
  model_in_use = ft.Text("GPT-4o", size=10, color=ft.Colors.GREY_500)
  
  chat_name = thread.title if thread else "New Thread"
  chatwindow_header = ft.Container(
    ft.Row([
      ft.Text(chat_name, size=14, text_align=ft.TextAlign.LEFT, weight=ft.FontWeight.W_500, expand=True, color=ft.Colors.PRIMARY),
      ft.IconButton(
          icon=ft.Icons.MORE_VERT_ROUNDED,
          tooltip="More",
          style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
          on_click=lambda e: print("Show chat settings"),
        )
    ], expand=True, height=40),
    bgcolor=ft.Colors.SURFACE, expand=True, padding=ft.padding.only(10,4,4,4),
    border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
  )

  # Message display logic
  if messages:
    message_list = ft.ListView(
      controls=[ft.Text(f"{m.role}: {m.content}") for m in messages],
      spacing=10,
      auto_scroll=True
    )
  else:
    message_list = ft.Text("No messages yet.")

  # # Determines if the chatbox is visible
  # if self.llm_configured():
  #   self.message_form.visible = True
  #   self.message_controls.visible = True
  #   if self.tools.tools_configured():
  #     self.tools # Set the thread id
  #     self.tools.visible = True
  # else:
  #   self.tools.visible = False
  #   self.message_form.visible = False
  #   self.message_controls.visible = False
  
  # # The chatwindow_header, shows the chat name and a settings button 3 button stack
  # self.chatwindow_header = ft.Container(
  #   ft.Row([
  #     ft.Text(self.chats[self.active_thread].name, size=14, text_align=ft.TextAlign.LEFT, weight=ft.FontWeight.W_500, expand=True, color=ft.Colors.PRIMARY),
  #     ft.IconButton(
  #         icon=ft.Icons.MORE_VERT_ROUNDED,
  #         tooltip="More",
  #         style=ft.ButtonStyle(shape=ft.RoundedRectangleBorder(radius=3)),
  #         on_click=self.show_chat_settings,
  #       )
  #   ], expand=True, height=40),
  #   bgcolor=ft.Colors.SURFACE, expand=True, padding=ft.padding.only(10,4,4,4),
  #   border=ft.border.only(bottom=ft.BorderSide(1, ft.Colors.SECONDARY_CONTAINER))
  # )

  # Returns the chat window content
  return ft.Stack([
    # Chat thread messages
    ft.Container(
      content=ft.SelectionArea(content=message_list) if llm_configured() else ft.Text("Configure LLM"),
      padding=ft.padding.only(0, 48, 0, 110),
      expand=True,
      alignment=ft.Alignment.TOP_CENTER,
    ),

    # Message form / Chatbox
    ft.Row([
      ft.Stack([
        ft.Column([
          ft.Container(
            content=ft.Column([
              ft.Container(
                border_radius=ft.BorderRadius(5, 5, 5, 5),
                padding=ft.padding.only(4, -5, 4, 0),
                margin=ft.margin.only(0, 0, 0, 0),
                bgcolor=ft.Colors.SECONDARY_CONTAINER,
                on_click=focus_message_form,
                content=ft.Column(
                  [
                    message_form,
                    ft.Row([
                      tools,
                      ft.Container(
                        content=ft.Row([
                        message_controls,
                      ], spacing=0, alignment=ft.MainAxisAlignment.END),
                        expand=True
                      )
                      ,
                    ], spacing=0),
                  ],
                  alignment="center",
                  horizontal_alignment="end", spacing=0,
                ),
              ),
              model_in_use,
              ], alignment="end", horizontal_alignment=ft.CrossAxisAlignment.CENTER, spacing=0,
            ),
            width=784,
            padding = ft.padding.only(14, 0, 14, 0),
            alignment=ft.Alignment.BOTTOM_CENTER,
            bgcolor=ft.Colors.SURFACE,
          ),
        ], alignment="end", spacing=0),
        ],
        alignment=ft.Alignment.BOTTOM_CENTER,
        expand=True,
        clip_behavior=ft.ClipBehavior.ANTI_ALIAS,
      ),
    ], expand=True, alignment=ft.Alignment.BOTTOM_CENTER, spacing=0),

    # Chat thread header
    chatwindow_header if llm_configured() else ft.Container(),
  ])