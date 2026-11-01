/** Text fit to show for whatever was thrown. */
export function errorMessage(error: unknown): string {
    return error instanceof Error ? error.message : 'Something went wrong.';
}
