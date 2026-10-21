"""A plain text box that receives the pasted dictation; dumps its contents to a file."""

import sys
import tkinter as tk

out_path = sys.argv[1]
root = tk.Tk()
root.title("paste-target")
root.geometry("600x200+50+50")
text = tk.Text(root)
text.pack(fill="both", expand=True)
text.focus_set()


def dump():
    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(text.get("1.0", "end-1c"))
    root.after(250, dump)


dump()
root.mainloop()
