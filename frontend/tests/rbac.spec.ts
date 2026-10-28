import { expect, type Page, test } from "@playwright/test"
import { createUser } from "./utils/privateApi"
import { randomEmail, randomPassword } from "./utils/random"
import { logInAsNewUser } from "./utils/user"

const sidebarLink = (page: Page, name: string) =>
  page.getByRole("link", { name, exact: true })

async function changeRoleInUsersTable(
  page: Page,
  email: string,
  roleLabel: string,
) {
  await page.goto("/admin")
  await page
    .getByRole("row")
    .filter({ hasText: email })
    .getByRole("button")
    .click()
  await page.getByRole("menuitem", { name: "Edit User" }).click()
  await page.getByRole("combobox", { name: "Role" }).click()
  await page.getByRole("option", { name: roleLabel }).click()
  await page.getByRole("button", { name: "Save" }).click()
  await expect(page.getByText("User updated successfully")).toBeVisible()
}

test.describe("Member", () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test.beforeEach(async ({ page }) => {
    await logInAsNewUser(page, "member")
  })

  test("Sidebar hides users and metrics links", async ({ page }) => {
    await expect(sidebarLink(page, "Dashboard")).toBeVisible()
    await expect(sidebarLink(page, "Items")).toBeVisible()
    await expect(sidebarLink(page, "Users")).toHaveCount(0)
    await expect(sidebarLink(page, "Metrics")).toHaveCount(0)
  })

  for (const path of ["/admin", "/metrics"]) {
    test(`Opening ${path} directly shows Access denied without logging out`, async ({
      page,
    }) => {
      await page.goto(path)

      await expect(page.getByTestId("forbidden")).toBeVisible()
      await expect(page).toHaveURL(new RegExp(`${path}$`))
      await expect(sidebarLink(page, "Dashboard")).toBeVisible()
    })
  }

  test("Access denied page links back to the dashboard", async ({ page }) => {
    await page.goto("/admin")

    await page.getByRole("button", { name: "Back to Dashboard" }).click()

    await expect(page).toHaveURL(/\/$/)
    await expect(
      page.getByText("Welcome back, nice to see you again!"),
    ).toBeVisible()
  })

  test("Danger zone tab is visible", async ({ page }) => {
    await page.goto("/settings")
    await expect(page.getByRole("tab", { name: "Danger zone" })).toBeVisible()
  })
})

test.describe("Manager", () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test.beforeEach(async ({ page }) => {
    await logInAsNewUser(page, "manager")
  })

  test("Sidebar shows users and metrics links", async ({ page }) => {
    await expect(sidebarLink(page, "Users")).toBeVisible()
    await expect(sidebarLink(page, "Metrics")).toBeVisible()
  })

  test("Users page is read-only", async ({ page }) => {
    await page.goto("/admin")

    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible()
    await expect(
      page.getByText("View user accounts and their roles"),
    ).toBeVisible()
    await expect(page.getByRole("row").nth(1)).toBeVisible()
    await expect(page.getByRole("button", { name: "Add User" })).toHaveCount(0)
    await expect(page.getByRole("table").getByRole("button")).toHaveCount(0)
  })

  test("Metrics page shows the metric cards", async ({ page }) => {
    await page.goto("/metrics")

    await expect(page.getByRole("heading", { name: "Metrics" })).toBeVisible()
    await expect(page.getByTestId("metric-card")).toHaveCount(6)
  })
})

test.describe("Admin", () => {
  test("Sidebar shows users and metrics links", async ({ page }) => {
    await page.goto("/")

    await expect(sidebarLink(page, "Users")).toBeVisible()
    await expect(sidebarLink(page, "Metrics")).toBeVisible()
  })

  test("Can create a user with the manager role", async ({ page }) => {
    const email = randomEmail()
    const password = randomPassword()
    await page.goto("/admin")

    await page.getByRole("button", { name: "Add User" }).click()
    await page.getByPlaceholder("Email").fill(email)
    await page.getByPlaceholder("Password").first().fill(password)
    await page.getByPlaceholder("Password").last().fill(password)
    await page.getByRole("combobox", { name: "Role" }).click()
    await page.getByRole("option", { name: "Manager" }).click()
    await page.getByRole("button", { name: "Save" }).click()

    await expect(page.getByText("User created successfully")).toBeVisible()
    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow.getByText("Manager", { exact: true })).toBeVisible()
  })

  test("Can change the role of a user", async ({ page }) => {
    const email = randomEmail()
    await createUser({ email, password: randomPassword() })

    await changeRoleInUsersTable(page, email, "Manager")

    const userRow = page.getByRole("row").filter({ hasText: email })
    await expect(userRow.getByText("Manager", { exact: true })).toBeVisible()
  })

  test("Danger zone tab is hidden", async ({ page }) => {
    await page.goto("/settings")

    await expect(page.getByRole("tab", { name: "My profile" })).toBeVisible()
    await expect(page.getByRole("tab", { name: "Danger zone" })).toHaveCount(0)
  })

  // A new admin is the newest user, so their row is on the first page of the table
  test.describe("with a newly created account", () => {
    test.use({ storageState: { cookies: [], origins: [] } })

    test("Own row has no actions menu", async ({ page }) => {
      const { email } = await logInAsNewUser(page, "admin")
      await page.goto("/admin")

      const ownRow = page.getByRole("row").filter({ hasText: email })
      await expect(ownRow.getByText("You", { exact: true })).toBeVisible()
      await expect(ownRow.getByRole("button")).toHaveCount(0)
    })
  })
})

test.describe("Role changes", () => {
  test.use({ storageState: { cookies: [], origins: [] } })

  test("Promoted member sees manager links after reload without logging in again", async ({
    page,
    browser,
    baseURL,
  }) => {
    const { email } = await logInAsNewUser(page, "member")
    await expect(sidebarLink(page, "Users")).toHaveCount(0)

    const adminContext = await browser.newContext({
      baseURL,
      storageState: "playwright/.auth/user.json",
    })
    await changeRoleInUsersTable(await adminContext.newPage(), email, "Manager")
    await adminContext.close()

    await page.reload()
    await expect(sidebarLink(page, "Users")).toBeVisible()
  })
})
