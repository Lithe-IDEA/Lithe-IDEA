import { afterAll, expect, test } from "bun:test";
import { act, useState } from "react";
import type { Root } from "react-dom/client";
import { LocaleProvider } from "@/i18n/locale-provider";
import { installHappyDom } from "@/test-utils/happy-dom";
import SettingsPathInput from "./settings-path-input";

const restoreDom = installHappyDom();
afterAll(restoreDom);
const { createRoot } = await import("react-dom/client");

test("Escape preserves a custom toolchain draft while manual edits and clearing still work", async () => {
  const environment = globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean };
  const previousAct = environment.IS_REACT_ACT_ENVIRONMENT;
  const changes: string[] = [];
  const host = document.createElement("div");
  let root: Root | undefined;
  function ProjectPath() {
    const [value, setValue] = useState("C:/toolchains/initial-jdk");
    return (
      <SettingsPathInput
        value={value}
        candidates={[]}
        label="Project JDK"
        placeholder="Automatic"
        onChange={(next) => {
          changes.push(next);
          setValue(next);
        }}
      />
    );
  }
  try {
    environment.IS_REACT_ACT_ENVIRONMENT = true;
    document.body.append(host);
    root = createRoot(host);
    const mountedRoot = root;
    await act(async () =>
      mountedRoot.render(
        <LocaleProvider language="en-US">
          <ProjectPath />
        </LocaleProvider>,
      ),
    );
    const input = host.querySelector<HTMLInputElement>('input[aria-label="Project JDK"]')!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    const edit = (value: string) =>
      act(async () => {
        setValue.call(input, value);
        input.dispatchEvent(new Event("input", { bubbles: true }));
      });
    await edit("C:/toolchains/custom-jdk");
    expect(changes).toEqual(["C:/toolchains/custom-jdk"]);
    expect(input.getAttribute("aria-expanded")).toBe("false");
    await act(async () =>
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })),
    );
    expect(input.value).toBe("C:/toolchains/custom-jdk");
    expect(changes).toEqual(["C:/toolchains/custom-jdk"]);
    await edit("C:/toolchains/another-jdk");
    expect(input.value).toBe("C:/toolchains/another-jdk");
    await edit("");
    expect(input.value).toBe("");
    expect(changes[changes.length - 1]).toBe("");
  } finally {
    try {
      await act(async () => root?.unmount());
    } finally {
      host.remove();
      if (previousAct === undefined) delete environment.IS_REACT_ACT_ENVIRONMENT;
      else environment.IS_REACT_ACT_ENVIRONMENT = previousAct;
    }
  }
});
