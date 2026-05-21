import { NextResponse } from "next/server";
import { ZodError } from "zod";

type ApiRouteHandler<Args extends unknown[]> = (...args: Args) => Response | Promise<Response>;

type ApiRouteOptions = {
  defaultStatus?: number;
};

function responseErrorMessage(status: number) {
  if (status === 401) return "Unauthorized";
  if (status === 423) return "Sensitive data is locked";
  return "Request failed";
}

export function apiErrorResponse(error: unknown, options: ApiRouteOptions = {}): NextResponse {
  if (error instanceof Response) {
    return NextResponse.json({ error: responseErrorMessage(error.status) }, { status: error.status });
  }

  if (error instanceof ZodError) {
    return NextResponse.json(
      {
        error: "Invalid request",
        issues: error.issues.map((issue) => ({ path: issue.path.join("."), message: issue.message })),
      },
      { status: 400 },
    );
  }

  const status = options.defaultStatus ?? 500;
  const message = error instanceof Error ? error.message : String(error);
  return NextResponse.json({ error: message }, { status });
}

export function apiHandler<Args extends unknown[]>(handler: ApiRouteHandler<Args>, options: ApiRouteOptions = {}) {
  return async (...args: Args) => {
    try {
      return await handler(...args);
    } catch (error) {
      return apiErrorResponse(error, options);
    }
  };
}
