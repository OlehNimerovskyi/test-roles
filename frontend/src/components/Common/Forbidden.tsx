import { Link } from "@tanstack/react-router"
import { ShieldX } from "lucide-react"

import { Button } from "@/components/ui/button"

const Forbidden = () => {
  return (
    <div
      className="flex flex-col items-center justify-center py-24 text-center"
      data-testid="forbidden"
    >
      <div className="rounded-full bg-muted p-4 mb-4">
        <ShieldX className="h-8 w-8 text-muted-foreground" />
      </div>
      <span className="text-6xl font-bold leading-none mb-2">403</span>
      <h1 className="text-2xl font-bold mb-2">Access denied</h1>
      <p className="text-muted-foreground mb-6 max-w-md">
        You don't have permission to view this page. If you think this is a
        mistake, contact an administrator.
      </p>
      <Link to="/">
        <Button>Back to Dashboard</Button>
      </Link>
    </div>
  )
}

export default Forbidden
